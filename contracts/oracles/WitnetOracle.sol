// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "../interfaces/IOracle.sol";

// We can import the original `IWitnetPriceRouter` because this repository is using a legacy Solidity compiler version
// that is no longer supported by the Witnet contracts.
interface IWitnetPriceRouter {
    function currencyPairId(string memory) external pure returns (bytes32);
    function supportsCurrencyPair(bytes32) external view returns (bool);
    function valueFor(bytes32) external view returns(int256,uint256,uint256);
}

contract WitnetOracle is IOracle {
    using BoringMath for uint256;

    // This is the contract where price data coming from Witnet can be queried.
    IWitnetPriceRouter immutable public router;

    // These are the "third" intermediary assets that can be used for routing price pairs.
    // E.g. ETH/USD can be composed from ETH/USDT and USDT/USD as long as USDT is a "third" here.
    string[] thirds;

    /**
     * IMPORTANT: pass the WitnetPriceRouter address depending on
     * the network you are using! Please find available addresses here:
     * https://docs.witnet.io/smart-contracts/price-feeds/contract-addresses
     */
    constructor(IWitnetPriceRouter _router, string[] memory _thirds) public {
        router = _router;
        thirds = _thirds;
    }

    // Calculates the latest exchange rate between a `base` asset and a `quote` asset, as identified by a pair ID.
    // That is, how many units of `quote` does 1 unit of `base` buy.
    function _get(
        uint8 _desiredDecimals,
        uint8 _basePairDecimals,
        bytes4 _basePairId,
        uint8 _quotePairDecimals,
        bytes4 _quotePairId,
        bool _quotePairIsReverse
    ) internal view returns (bool _success, uint256 _price) {
        if (_quotePairDecimals > 0) {
            // This is a routed price pair, we need to multiply or divide the prices depending on whether the quote
            // price pair is direct (THIRD/QUOTE) or reverse (QUOTE/THIRD).
            (int256 baseIntPrice,,uint256 baseStatus) = router.valueFor(_basePairId);
            (int256 quoteIntPrice,,uint256 quoteStatus) = router.valueFor(_quotePairId);

            // Early escape if any error is returned
            if (baseStatus != 200 || quoteStatus != 200) {
                return (false, 0);
            }

            if (_quotePairIsReverse) {
                // If the quote pair is reversely routed, `_quotePairId` is used as a divider to invert the pair.
                uint256 divider = 10 ** uint256(36 + _basePairDecimals - _quotePairDecimals - _desiredDecimals);
                _price = 1e36 * uint256(baseIntPrice) / uint256(quoteIntPrice) / divider;
            } else {
                uint256 divider = 10 ** uint256(36 + _basePairDecimals + _quotePairDecimals - _desiredDecimals);
                _price = 1e36 * uint256(baseIntPrice) * uint256(quoteIntPrice) / divider;
            }
        } else {
            // This is a native price pair, we just need to adjust the decimals if needed.
            (int256 baseIntPrice,,) = router.valueFor(_basePairId);
            uint256 divider = 10 ** uint256(36 + _basePairDecimals - _desiredDecimals);
            _price = 1e36 * uint256(baseIntPrice) / divider;
        }

        return (true, _price);
    }

    function _charFromNumber(uint8 _number) public pure returns (bytes1) {
        return bytes1(uint8(48 + _number));
    }

    function _findRouteWithDecimals(
        uint8 _baseDecimals,
        string memory _base,
        uint8 _quoteDecimals,
        string memory _quote,
        string memory _third
    ) public view returns (
        bytes4 _basePairId4,
        bytes4 _quotePairId4,
        bool _quotePairIsInverse
    ) {
        string memory basePairCaption = string(abi.encodePacked("Price-", _base, "/", _third ,"-", _charFromNumber(_baseDecimals)));
        bytes4 basePairId = bytes4(router.currencyPairId(basePairCaption));
        // Early escape if the BASE → THIRD pair is not supported.
        if (!router.supportsCurrencyPair(basePairId)) {
            return (0, 0, false);
        }

        // Try to find direct route via BASE/THIRD * THIRD/QUOTE.
        string memory quotePairCaption = string(abi.encodePacked("Price-", _third, "/", _quote ,"-", _charFromNumber(_quoteDecimals)));
        bytes4 quotePairId = bytes4(router.currencyPairId(quotePairCaption));
        if (router.supportsCurrencyPair(quotePairId)) {
            _basePairId4 = bytes4(basePairId);
            _quotePairId4 = bytes4(quotePairId);
            return (_basePairId4, _quotePairId4, false);
        }

        // Try to find reverse route via BASE/THIRD / QUOTE/THIRD.
        quotePairCaption = string(abi.encodePacked("Price-", _quote, "/", _third ,"-", _charFromNumber(_quoteDecimals)));
        quotePairId = bytes4(router.currencyPairId(quotePairCaption));
        if (router.supportsCurrencyPair(quotePairId)) {
            _basePairId4 = bytes4(basePairId);
            _quotePairId4 = bytes4(quotePairId);
            return (_basePairId4, _quotePairId4, true);
        }

        return (0, 0, false);
    }

    function _findRoute(
        string memory _base,
        string memory _quote,
        string memory _third
    ) public view returns (uint8, bytes4, uint8, bytes4, bool) {
        // Try to find a 6 + 6 decimals routed pair.
        (bytes4 basePairId, bytes4 quotePairId, bool reverse) = _findRouteWithDecimals(6, _base, 6, _quote, _third);
        if (quotePairId > 0) {
            return (6, basePairId, 6, quotePairId, reverse);
        }

        // Try to find a 6 + 9 decimals routed pair.
        (basePairId, quotePairId, reverse) = _findRouteWithDecimals(6, _base, 9, _quote, _third);
        if (quotePairId > 0) {
            return (6, basePairId, 9, quotePairId, reverse);
        }

        // Try to find a 9 + 6 decimals routed pair.
        (basePairId, quotePairId, reverse) = _findRouteWithDecimals(9, _base, 6, _quote, _third);
        if (quotePairId > 0) {
            return (9, basePairId, 6, quotePairId, reverse);
        }

        // Try to find a 9 + 9 decimals routed pair.
        (basePairId, quotePairId, reverse) = _findRouteWithDecimals(9, _base, 9, _quote, _third);
        if (quotePairId > 0) {
            return (9, basePairId, 9, quotePairId, reverse);
        }

        return (0, 0, 0, 0, false);
    }

    function getDataParameter(
        string memory _base,
        string memory _quote,
        uint8 desiredDecimals
    ) public view returns (bool, bytes memory) {

        // Try to find a native 6-decimals pair.
        string memory nativePairCaption = string(abi.encodePacked("Price-", _base, "/", _quote, "-", _charFromNumber(6)));
        bytes4 nativePairId = bytes4(router.currencyPairId(nativePairCaption));
        if (router.supportsCurrencyPair(nativePairId)) {
            return (true, abi.encode(desiredDecimals, 6, nativePairId, 0, 0, false));
        }

        // Try to find a native 9-decimals pair.
        nativePairCaption = string(abi.encodePacked("Price-", _base, "/", _quote, "-", _charFromNumber(9)));
        nativePairId = bytes4(router.currencyPairId(nativePairCaption));
        if (router.supportsCurrencyPair(nativePairId)) {
            return (true, abi.encode(desiredDecimals, 9, nativePairId, 0, 0, false));
        }

        // Try to find a route from BASE to QUOTE through BASE/THIRD * THIRD/QUOTE or BASE/THIRD / QUOTE/THIRD.
        for (uint i; i < thirds.length; i++) {
            string memory third = thirds[i];
            (uint8 basePairDecimals, bytes4 basePairId, uint8 quotePairDecimals, bytes4 quotePairId, bool reverse) = _findRoute(_base, _quote, third);
            if (basePairDecimals > 0 && quotePairDecimals > 0) {
                return (true, abi.encode(desiredDecimals, basePairDecimals, basePairId, quotePairDecimals, quotePairId, reverse));
            }
        }

        // Use the default direct route, even if not supported just yet.
        return (false, abi.encode(desiredDecimals, 6, nativePairId, 0, 0, false));
    }

    // Get the latest exchange rate
    /// @inheritdoc IOracle
    function get(bytes calldata data) public override returns (bool, uint256) {
        return peek(data);
    }

    // Check the last exchange rate without any state changes
    /// @inheritdoc IOracle
    function peek(bytes calldata data) public view override returns (bool, uint256) {
        (
            uint8 desiredDecimals,
            uint8 basePairDecimals,
            bytes4 basePairId,
            uint8 quotePairDecimals,
            bytes4 quotePairId,
            bool quotePairIsReverse
        ) = abi.decode(data, (uint8, uint8, bytes4, uint8, bytes4, bool));
        return _get(desiredDecimals, basePairDecimals, basePairId, quotePairDecimals, quotePairId, quotePairIsReverse);
    }

    // Check the current spot exchange rate without any state changes
    /// @inheritdoc IOracle
    function peekSpot(bytes calldata data) external view override returns (uint256 rate) {
        (, rate) = peek(data);
    }

    /// @inheritdoc IOracle
    function name(bytes calldata) public view override returns (string memory) {
        return "Witnet";
    }

    /// @inheritdoc IOracle
    function symbol(bytes calldata) public view override returns (string memory) {
        return "WIT";
    }
}
