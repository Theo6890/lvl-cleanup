// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ILevelOracle} from "../interfaces/ILevelOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

struct TokenConfig {
    /// @dev 10 ^ token decimals
    uint256 baseUnits;
    /// @dev precision of price posted by reporter
    uint256 priceUnits;
    /// @dev chainlink pricefeed used to compare with posted price
    AggregatorV3Interface chainlinkPriceFeed;
    uint256 chainlinkDeviation;
    uint256 chainlinkTimeout;
}

/// @title PriceFeed
/// @notice Price feed with guard from
contract LevelOracle is Ownable, ILevelOracle {
    mapping(address => TokenConfig) public tokenConfig;
    /// @dev This price feed returns price in precision of 10 ^ (30 - token decimals)
    uint256 constant VALUE_PRECISION = 1e30;
    /// @notice precision used for spread, deviation
    uint256 constant PRECISION = 1e6;
    uint256 public constant PRICE_FEED_ERROR = 1 hours;
    uint256 public constant PRICE_FEED_INACTIVE = 5 minutes;
    uint256 public constant PRICE_FEED_ERROR_SPREAD = 5e4; // 5%
    uint256 public constant PRICE_FEED_INACTIVE_SPREAD = 2e3; // 0.2%

    /// @notice listed tokens, for inspection only
    address[] public whitelistedTokens;
    /// @notice last reported price
    mapping(address => uint256) public lastAnswers;
    mapping(address => uint256) public lastAnswerTimestamp;
    mapping(address => uint256) public lastAnswerBlock;

    constructor() Ownable(msg.sender) {}

    // ============ Mutative functions ============

    function postPrices(address[] calldata tokens, uint256[] calldata prices) external {
        // require(isReporter[msg.sender], "PriceFeed:unauthorized");
        uint256 count = tokens.length;
        require(prices.length == count, "PriceFeed:lengthMissMatch");
        for (uint256 i = 0; i < count;) {
            _postPrice(tokens[i], prices[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ============ View functions ============
    function getMultiplePrices(address[] calldata tokens, bool max) external view returns (uint256[] memory) {
        uint256 len = tokens.length;
        uint256[] memory result = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            result[i] = _getPrice(tokens[i], max);
            unchecked {
                ++i;
            }
        }

        return result;
    }

    function getPrice(address token, bool max) external view returns (uint256) {
        return _getPrice(token, max);
    }

    function getLastPrice(address token) external view returns (uint256 lastPrice) {
        (lastPrice,) = _getLastPrice(token);
    }

    // =========== Restrited functions ===========

    /// @notice config watched token
    /// @param token token address
    /// @param tokenDecimals token decimals
    /// @param priceFeed the chainlink price feed used for reference
    /// @param priceDecimals precision of price posted by reporter, not the chainlink price feed
    function configToken(
        address token,
        uint256 tokenDecimals,
        address priceFeed,
        uint256 priceDecimals,
        uint256 chainlinkTimeout,
        uint256 chainlinkDeviation
    ) external onlyOwner {
        // require(priceFeed != address(0), "PriceFeed:invalidPriceFeed");
        require(tokenDecimals != 0 && priceDecimals != 0, "PriceFeed:invalidDecimals");
        // require(chainlinkTimeout != 0, "PriceFeed:invalidTimeout");
        // require(chainlinkDeviation != 0 && chainlinkDeviation < PRECISION / 2, "PriceFeed:invalidChainlinkDeviation");

        if (tokenConfig[token].baseUnits == 0) {
            whitelistedTokens.push(token);
        }

        tokenConfig[token] = TokenConfig({
            baseUnits: 10 ** tokenDecimals,
            priceUnits: 10 ** priceDecimals,
            chainlinkPriceFeed: AggregatorV3Interface(priceFeed),
            chainlinkTimeout: chainlinkTimeout,
            chainlinkDeviation: chainlinkDeviation
        });
        emit TokenAdded(token);
    }

    // ========= Internal functions ==========
    /// @notice report token price
    /// allow some authorized reporters only
    function _postPrice(address token, uint256 price) internal {
        TokenConfig memory config = tokenConfig[token];
        require(config.baseUnits > 0, "PriceFeed:tokenNotConfigured");
        uint256 normalizedPrice = (price * VALUE_PRECISION) / config.baseUnits / config.priceUnits;
        lastAnswers[token] = normalizedPrice;
        lastAnswerTimestamp[token] = block.timestamp;
        lastAnswerBlock[token] = block.number;
        emit PricePosted(token, normalizedPrice);
    }

    function _getPrice(address token, bool max) internal view returns (uint256) {
        _getLastPrice(token);
    }

    function _getLastPrice(address token) internal view returns (uint256 price, uint256 timestamp) {
        return (lastAnswers[token], lastAnswerTimestamp[token]);
    }

    // =========== Events ===========
    event ReporterAdded(address indexed);
    event ReporterRemoved(address indexed);
    event PricePosted(address indexed token, uint256 price);
    event TokenAdded(address indexed token);
}
