// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "openzeppelin/interfaces/IERC20Metadata.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {SignedIntOps} from "../../lib/SignedInt.sol";
import {MathUtils} from "../../lib/MathUtils.sol";
import {PositionUtils} from "../../lib/PositionUtils.sol";
import {ILevelOracle} from "../../interfaces/ILevelOracle.sol";
import {ILPToken} from "../../interfaces/ILPToken.sol";
import {IPool, Side, TokenWeight} from "../../interfaces/IPool.sol";

import {PoolAdmin} from "./PoolAdmin.sol";
import {
    Position,
    PoolTokenInfo,
    Fee,
    AssetInfo,
    PRECISION,
    LP_INITIAL_PRICE,
    MAX_BASE_SWAP_FEE,
    MAX_TAX_BASIS_POINT,
    MAX_POSITION_FEE,
    MAX_LIQUIDATION_FEE,
    MAX_INTEREST_RATE,
    MAX_ASSETS,
    MAX_MAINTENANCE_MARGIN
} from "./PoolStorage.sol";
import {PoolErrors} from "./PoolErrors.sol";
import {IPoolHook} from "../../interfaces/IPoolHook.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

contract Pool is Initializable, ReentrancyGuardUpgradeable, PoolAdmin, IPool {
    using SignedIntOps for int256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    address public plp;

    constructor(address plp_) {
        _disableInitializers();
        plp = plp_;
    }

    // ========= View functions =========

    function getPoolAsset(address _token) external view returns (AssetInfo memory) {
        return assetsInfo[_token];
    }

    function getPoolValue(bool _max) external view returns (uint256) {
        return _getPoolValue(_max);
    }

    function calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount)
        external
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 feeAmount)
    {
        (outAmount, outAmountAfterFee, feeAmount,) = _calcRemoveLiquidity(_tokenOut, _lpAmount);
    }

    // ============= Mutative functions =============

    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        nonReentrant
        onlyListedToken(_token)
    {
        _accrueInterest(_token);
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amountIn);
        _amountIn = _requireAmount(_getAmountIn(_token));

        (uint256 amountInAfterDaoFee, uint256 daoFee, uint256 lpAmount) = _calcAddLiquidity(_token, _amountIn);
        if (lpAmount < _minLpAmount) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_token].feeReserve += daoFee;
        assetsInfo[_token].poolAmount += amountInAfterDaoFee;
        refreshVirtualPoolValue();

        ILPToken(plp).mint(_to, lpAmount);
        emit LiquidityAdded(msg.sender, _token, _amountIn, lpAmount, daoFee);
    }

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
        nonReentrant
        onlyAsset(_tokenOut)
    {
        // TODO what about accrual interest for PLP
        _accrueInterest(_tokenOut);
        _requireAmount(_lpAmount);
        ILPToken lpToken = ILPToken(plp);

        (, uint256 outAmountAfterFee, uint256 daoFee, uint256 tokenOutPrice) =
            _calcRemoveLiquidity(_tokenOut, _lpAmount);
        if (outAmountAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_tokenOut].feeReserve += daoFee;
        _decreasePoolAmount(_tokenOut, outAmountAfterFee + daoFee, tokenOutPrice);
        refreshVirtualPoolValue();

        lpToken.burnFrom(msg.sender, _lpAmount);
        _doTransferOut(_tokenOut, _to, outAmountAfterFee);

        emit LiquidityRemoved(msg.sender, _tokenOut, _lpAmount, outAmountAfterFee, daoFee);
    }

    function refreshVirtualPoolValue() public {
        virtualPoolValue = (_getPoolValue(true) + _getPoolValue(false)) / 2;
    }

    // ======== internal functions =========
    function _calcAddLiquidity(address _token, uint256 _amountIn)
        internal
        view
        returns (uint256 amountInAfterFee, uint256 daoFee, uint256 lpAmount)
    {
        uint256 tokenPrice = _getPrice(_token, false);
        uint256 valueChange = _amountIn * tokenPrice;

        uint256 _fee = _calcFeeRate(_token, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, true);
        uint256 userAmount = MathUtils.frac(_amountIn, PRECISION - _fee, PRECISION);
        (daoFee,) = _calcDaoFee(_amountIn - userAmount);
        amountInAfterFee = _amountIn - daoFee;

        uint256 lpSupply = ILPToken(plp).totalSupply();
        if (lpSupply == 0) {
            lpAmount = MathUtils.frac(userAmount, tokenPrice, LP_INITIAL_PRICE);
        } else {
            // TODO: verify division denomitor is correct
            lpAmount = (userAmount * tokenPrice * lpSupply) / _getPoolValue(true);
        }
    }

    function _calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount)
        internal
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 daoFee, uint256 tokenPrice)
    {
        tokenPrice = _getPrice(_tokenOut, true);
        uint256 poolValue = _getPoolValue(true);
        uint256 totalSupply = ILPToken(plp).totalSupply();
        uint256 valueChange = (_lpAmount * poolValue) / totalSupply;
        uint256 _fee = _calcFeeRate(_tokenOut, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, false);
        outAmount = (_lpAmount * poolValue) / totalSupply / tokenPrice;
        outAmountAfterFee = MathUtils.frac(outAmount, PRECISION - _fee, PRECISION);
        (daoFee,) = _calcDaoFee(outAmount - outAmountAfterFee);
    }

    function _getAmountIn(address _token) internal returns (uint256 amount) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        amount = balance - poolTokens[_token].poolBalance;
        poolTokens[_token].poolBalance = balance;
    }

    function _accrueInterest(address _token) internal returns (uint256) {
        PoolTokenInfo memory tokenInfo = poolTokens[_token];
        AssetInfo memory asset = assetsInfo[_token];
        uint256 _now = block.timestamp;
        if (tokenInfo.lastAccrualTimestamp == 0 || asset.poolAmount == 0) {
            tokenInfo.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
        } else {
            uint256 nInterval = (_now - tokenInfo.lastAccrualTimestamp) / accrualInterval;
            if (nInterval == 0) {
                return tokenInfo.borrowIndex;
            }

            tokenInfo.borrowIndex += (nInterval * interestRate * asset.reservedAmount) / asset.poolAmount;
            tokenInfo.lastAccrualTimestamp += nInterval * accrualInterval;
        }

        poolTokens[_token] = tokenInfo;
        emit InterestAccrued(_token, tokenInfo.borrowIndex);
        return tokenInfo.borrowIndex;
    }

    function _calcFeeRate(
        address _token,
        uint256 _tokenPrice,
        uint256 _valueChange,
        uint256 _baseFee,
        uint256 _taxBasisPoint,
        bool _isIncrease
    ) internal view returns (uint256) {
        uint256 _targetValue = totalWeight == 0 ? 0 : (targetWeights[_token] * virtualPoolValue) / totalWeight;
        if (_targetValue == 0) {
            return _baseFee;
        }
        uint256 _currentValue = _tokenPrice * assetsInfo[_token].poolAmount;
        uint256 _nextValue = _isIncrease ? _currentValue + _valueChange : _currentValue - _valueChange;
        uint256 initDiff = MathUtils.diff(_currentValue, _targetValue);
        uint256 nextDiff = MathUtils.diff(_nextValue, _targetValue);
        if (nextDiff < initDiff) {
            uint256 feeAdjust = (_taxBasisPoint * initDiff) / _targetValue;
            return MathUtils.zeroCapSub(_baseFee, feeAdjust);
        } else {
            uint256 avgDiff = (initDiff + nextDiff) / 2;
            uint256 feeAdjust = avgDiff > _targetValue ? _taxBasisPoint : (_taxBasisPoint * avgDiff) / _targetValue;
            return _baseFee + feeAdjust;
        }
    }

    function _getPoolValue(bool _max) internal view returns (uint256 sum) {
        int256 aum;
        uint256[] memory prices = _getAllPrices(_max);
        for (uint256 i = 0; i < allAssets.length;) {
            address token = allAssets[i];
            assert(isAsset[token]); // double check
            AssetInfo memory asset = assetsInfo[token];
            uint256 price = prices[i];
            aum += (price * asset.poolAmount).toInt256();
            /* if (isStableCoin[token]) {
                aum += (price * asset.poolAmount).toInt256();
            } else {
                uint256 averageShortPrice = averageShortPrices[token];
                int256 shortPnl = 0;
                aum +=
                    (((asset.poolAmount - asset.reservedAmount) * price + asset.guaranteedValue).toInt256() - shortPnl);
            } */
            unchecked {
                ++i;
            }
        }

        // aum MUST not be negative. If it is, please debug
        return aum.toUint256();
    }

    function _getAllPrices(bool _max) internal view returns (uint256[] memory) {
        return oracle.getMultiplePrices(allAssets, _max);
    }

    function _decreasePoolAmount(address _token, uint256 _amount, uint256 _assetPrice) internal {
        AssetInfo memory asset = assetsInfo[_token];
        asset.poolAmount -= _amount;
        if (asset.poolAmount < asset.reservedAmount) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
        assetsInfo[_token] = asset;
    }

    function _getPrice(address _token, bool _max) internal view returns (uint256) {
        return oracle.getPrice(_token, _max);
    }

    function _calcDaoFee(uint256 _feeAmount) internal view returns (uint256 daoFee, uint256 lpFee) {
        daoFee = MathUtils.frac(_feeAmount, fee.daoFee, PRECISION);
        lpFee = _feeAmount - daoFee;
    }
}
