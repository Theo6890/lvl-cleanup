// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {SignedInt} from "../lib/SignedInt.sol";

enum Side {
    LONG,
    SHORT
}

struct TokenWeight {
    address token;
    uint256 weight;
}

interface IPool {




    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to) external;

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to) external;

    // =========== EVENTS ===========
    event SetOrderManager(address indexed orderManager);
    event IncreasePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralValue,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        uint256 feeValue
    );
    event UpdatePosition(
        bytes32 indexed key,
        uint256 size,
        uint256 collateralValue,
        uint256 entryPrice,
        uint256 entryInterestRate,
        uint256 reserveAmount,
        uint256 indexPrice
    );
    event DecreasePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralChanged,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        SignedInt pnl,
        uint256 feeValue
    );
    event ClosePosition(
        bytes32 indexed key,
        uint256 size,
        uint256 collateralValue,
        uint256 entryPrice,
        uint256 entryInterestRate,
        uint256 reserveAmount
    );
    event LiquidatePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        Side side,
        uint256 size,
        uint256 collateralValue,
        uint256 reserveAmount,
        uint256 indexPrice,
        SignedInt pnl,
        uint256 feeValue
    );
    event DaoFeeReduced(address indexed token, uint256 amount);
    event LiquidityAdded( address indexed sender, address token, uint256 amount, uint256 lpAmount, uint256 fee
    );
    event LiquidityRemoved(address indexed sender, address token, uint256 lpAmount, uint256 amountOut, uint256 fee
    );
    event Swap(
        address indexed sender, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 fee
    );

    event InterestAccrued(address indexed token, uint256 borrowIndex);
    event MaxLeverageChanged(uint256 maxLeverage);
    event MaxPositionSizeSet(uint256 maxPositionSize);
    event TrancheAdded(address indexed lpToken);
    event TokenRiskFactorUpdated(address indexed token);
    event PnLDistributed(address indexed asset, address indexed tranche, uint256 amount, bool hasProfit);
    event MaintenanceMarginChanged(uint256 ratio);
}
