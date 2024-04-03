// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

struct Token {
    address token;
    uint48 settleTime;
    uint48 settleDuration;
    uint152 settleRate; 
    uint8 status; 
}

struct Offer {
    uint8 offerType;
    bytes32 tokenId;
    address exToken;
    uint256 amount;
    uint256 value;
    uint256 collateral;
    uint256 filledAmount;
    uint8 status;
    address offeredBy;
    bool fullMatch;
}

struct Order {
    uint256 offerId;
    uint256 amount;
    address seller;
    address buyer;
    uint8 status;
}

struct Config {
    uint256 pledgeRate;
    uint256 feeRefund;
    uint256 feeSettle;
    address feeWallet;
}

contract TMarket is
    AccessControl,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    uint256 constant WEI6 = 10 ** 6;
    uint8 constant OFFER_BUY = 1;
    uint8 constant OFFER_SELL = 2;

    // Status
    // Offer status
    uint8 constant STATUS_OFFER_OPEN = 1;
    uint8 constant STATUS_OFFER_FILLED = 2;
    uint8 constant STATUS_OFFER_CANCELLED = 3;

    // Order Status
    uint8 constant STATUS_ORDER_OPEN = 1;
    uint8 constant STATUS_ORDER_SETTLE_FILLED = 2;
    uint8 constant STATUS_ORDER_SETTLE_CANCELLED = 3;
    uint8 constant STATUS_ORDER_CANCELLED = 3;

    // token status
    uint8 constant STATUS_TOKEN_ACTIVE = 1;
    uint8 constant STATUS_TOKEN_INACTIVE = 2;
    uint8 constant STATUS_TOKEN_SETTLE = 3;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    mapping(address => bool) public acceptedTokens;
    mapping(bytes32 => bool) public tokenCreated;
    mapping(bytes32 => Token) public tokens;
    mapping(uint256 => Offer) public offers;
    uint256 public lastOfferId;
    mapping(uint256 => Order) public orders;
    uint256 public lastOrderId;
    Config public config;

    // event
    event NewOffer(
        uint256 id,
        uint8 offerType,
        bytes32 tokenId,
        address exToken,
        uint256 amount,
        uint256 value,
        uint256 collateral,
        bool fullMatch,
        address doer
    );
    event NewToken(bytes32 tokenId, uint256 settleDuration);
    event NewOrder(
        uint256 id,
        uint256 offerId,
        uint256 amount,
        address seller,
        address buyer
    );

    event SettleFilled(
        uint256 orderId,
        uint256 value,
        uint256 fee,
        address doer
    );
    event SettleCancelled(
        uint256 orderId,
        uint256 value,
        uint256 fee,
        address doer
    );

    event CancelOrder(uint256 orderId, address doer);
    event CancelOffer(
        uint256 offerId,
        uint256 refundValue,
        uint256 refundFee,
        address doer
    );

    event UpdateAcceptedTokens(address[] tokens, bool isAccepted);

    event CloseOffer(uint256 offerId, uint256 refundAmount);

    event UpdateConfig(
        address oldFeeWallet,
        uint256 oldFeeSettle,
        uint256 oldFeeRefund,
        uint256 oldPledgeRate,
        address newFeeWallet,
        uint256 newFeeSettle,
        uint256 newFeeRefund,
        uint256 newPledgeRate
    );

    event TokenToSettlePhase(
        bytes32 tokenId,
        address token,
        uint256 settleRate,
        uint256 settleTime
    );
    event UpdateTokenStatus(bytes32 tokenId, uint8 oldValue, uint8 newValue);
    event TokenForceCancelSettlePhase(bytes32 tokenId);

    event Settle2Steps(uint256 orderId, bytes32 hash, address doer);

    event UpdateTokenSettleDuration(
        bytes32 tokenId,
        uint48 oldValue,
        uint48 newValue
    );

    constructor(address adminAddress, address feeWalletAddress) {
        require(adminAddress != address(0), "Admin address cannot be the zero address");
        require(feeWalletAddress != address(0), "Fee wallet address cannot be the zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(OPERATOR_ROLE, adminAddress);

        config.pledgeRate = WEI6; // 1:1
        config.feeWallet = feeWalletAddress;
        config.feeSettle = WEI6 / 40; // 2.5%
        config.feeRefund = WEI6 / 200; // 0.5%
    }

    ///////////////////////////
    ////// SYSTEM ACTION //////
    ///////////////////////////

    /**
     * @dev Convert value from sourceDecimals to targetDecimals.
     */
    function convertDecimals(
        uint256 value,
        uint8 sourceDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256 result) {
        if (sourceDecimals == targetDecimals) {
            result = value;
        } else if (sourceDecimals < targetDecimals) {
            result = value * (10**(targetDecimals - sourceDecimals));
        } else {
            result = value / (10**(sourceDecimals - targetDecimals));
        }
    }

    /**
     * @dev Convert value from sourceDecimals to targetDecimals, rounded up.
     */
    function convertDecimalsCeil(
        uint256 value,
        uint8 sourceDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256 result) {
        if (sourceDecimals == targetDecimals) {
            result = value;
        } else if (sourceDecimals < targetDecimals) {
            result = value * (10**(targetDecimals - sourceDecimals));
        } else {
            uint256 temp = 10**(sourceDecimals - targetDecimals);
            result = value / temp;
            if (value % temp != 0) {
                result += 1;
            }
        }
    }

    /**
    * @dev Creates a new token. Only addresses with the OPERATOR_ROLE role can call this function.
    * @param tokenId The unique identifier of the token.
    * @param settleDuration The duration of the settlement, in seconds, representing the time from the start of the transaction to when it can be settled.
    */
    function createToken(
        bytes32 tokenId,
        uint48 settleDuration
    ) external onlyRole(OPERATOR_ROLE) {
        require(settleDuration >= 24 * 60 * 60, "createToken: Minimum 24h for settling");//+
        require(!tokenCreated[tokenId], "createToken: Token already exists");
        tokenCreated[tokenId] = true;
        Token storage _token = tokens[tokenId];
        _token.settleDuration = settleDuration;
        _token.status = STATUS_TOKEN_ACTIVE;
        emit NewToken(tokenId, settleDuration);
    }

    /**
    * @dev Moves a token to the settlement phase. Only addresses with the OPERATOR_ROLE role can call this function.
    * @param tokenId The unique identifier of the token.
    * @param tokenAddress The contract address of the token.
    * @param settleRate The settlement rate, representing how many tokens can be exchanged for 1M points.
    */
    function tokenToSettlePhase(
        bytes32 tokenId,
        address tokenAddress,
        uint152 settleRate // how many token for 1M points
    ) external onlyRole(OPERATOR_ROLE) {
        Token storage _token = tokens[tokenId];
        require(tokenAddress != address(0), "tokenToSettlePhase: Invalid Token Address");
        require(settleRate > 0, "tokenToSettlePhase:Invalid Settle Rate");
        require(
            _token.status == STATUS_TOKEN_ACTIVE ||
                _token.status == STATUS_TOKEN_INACTIVE,
            "tokenToSettlePhase:Invalid Token Status"
        );
        _token.token = tokenAddress;
        _token.settleRate = settleRate;
        // update token settle status & time
        _token.status = STATUS_TOKEN_SETTLE;
        _token.settleTime = uint48(block.timestamp);

        emit TokenToSettlePhase(
            tokenId,
            tokenAddress,
            settleRate,
            block.timestamp
        );
    }

    /**
    * @param tokenId The unique identifier of the token.
    */
    function tokenToggleActivation(
        bytes32 tokenId
    ) external onlyRole(OPERATOR_ROLE) {
        Token storage _token = tokens[tokenId];
        uint8 fromStatus = _token.status;
        uint8 toStatus = fromStatus == STATUS_TOKEN_ACTIVE
            ? STATUS_TOKEN_INACTIVE
            : STATUS_TOKEN_ACTIVE;

        require(
            fromStatus == STATUS_TOKEN_ACTIVE ||
                fromStatus == STATUS_TOKEN_INACTIVE,
            "Cannot Change Token Status"
        );

        _token.status = toStatus;
        emit UpdateTokenStatus(tokenId, fromStatus, toStatus);
    }

    /**
    * @param tokenId The unique identifier of the token.
    */
    function tokenForceCancelSettlePhase(bytes32 tokenId) external onlyRole(OPERATOR_ROLE) {
        Token storage _token = tokens[tokenId];
        require(_token.status == STATUS_TOKEN_SETTLE, "Invalid Token Status");
        _token.status = STATUS_TOKEN_INACTIVE;
        emit TokenForceCancelSettlePhase(tokenId);
    }

    /**
    * @param tokenId The unique identifier of the token.
    * @param newValue The new settle duration value in seconds.
    */
    function updateSettleDuration(
        bytes32 tokenId,
        uint48 newValue
    ) external onlyRole(OPERATOR_ROLE) {
        require(newValue >= 24 * 60 * 60, "Minimum 24h for settling");
        Token storage _token = tokens[tokenId];
        uint48 oldValue = _token.settleDuration;
        _token.settleDuration = newValue;
        emit UpdateTokenSettleDuration(tokenId, oldValue, newValue);
    }

    /**
    * @param orderId The ID of the order to be canceled.
    */
    function forceCancelOrder(
        uint256 orderId
    ) public nonReentrant onlyRole(OPERATOR_ROLE) {
        Order storage order = orders[orderId];
        Offer storage offer = offers[order.offerId];
        require(order.status == STATUS_OFFER_OPEN, "Invalid Order Status");
        // PMA-3
        uint8 targetDecimals;
        if (offer.exToken == address(0)) {
            targetDecimals = 18;
        } else {
            targetDecimals = IERC20Metadata(offer.exToken).decimals();
        }

        // calculate refund value
        uint256 buyerRefundValue = convertDecimals(
            (order.amount * offer.value) / offer.amount,
            18, // source decimals
            targetDecimals 
        );
        uint256 sellerRefundValue = convertDecimals(
            (order.amount * offer.collateral) / offer.amount,
            18, // source decimals
            targetDecimals 
        );
        address buyer = order.buyer;
        address seller = order.seller;

        // refund
        if (offer.exToken == address(0)) {
            // refund ETH
            if (buyerRefundValue > 0 && buyer != address(0)) {
                (bool success, ) = buyer.call{value: buyerRefundValue}("");
                require(success, "Transfer Funds to Seller Fail");
            }
            if (sellerRefundValue > 0 && seller != address(0)) {
                (bool success, ) = seller.call{value: sellerRefundValue}("");
                require(success, "Transfer Funds to Seller Fail");
            }
        } else {
            IERC20 iexToken = IERC20(offer.exToken);
            if (buyerRefundValue > 0 && buyer != address(0)) {
                iexToken.safeTransfer(buyer, buyerRefundValue);
            }
            if (sellerRefundValue > 0 && seller != address(0)) {
                iexToken.safeTransfer(seller, sellerRefundValue);
            }
        }

        order.status = STATUS_ORDER_CANCELLED;
        emit CancelOrder(orderId, _msgSender());
    }

    /**
    * @param orderId The ID of the order being settled.
    * @param hash A hash representing transaction details or verification information, used for additional security or validation.
    */
    function settle2Steps(
        uint256 orderId,
        bytes32 hash
    ) public nonReentrant onlyRole(OPERATOR_ROLE) {
        Order storage order = orders[orderId];
        Offer storage offer = offers[order.offerId];
        Token storage token = tokens[offer.tokenId];

        // check condition
        require(token.status == STATUS_TOKEN_SETTLE, "Invalid Status");
        require(
            token.token != address(0) && token.settleRate > 0,
            "Token Not Set"
        );
        //PMA-5
        require(
            token.settleTime > 0,
            "Settling Time Not Started"
        );
        require(order.status == STATUS_ORDER_OPEN, "Invalid Order Status");

        uint8 targetDecimals;
        if (offer.exToken == address(0)) {
            targetDecimals = 18;
        } else {
            targetDecimals = IERC20Metadata(offer.exToken).decimals();
        }

        // calculate and adjust the precision of the settlement value
        uint256 collateral = convertDecimals(
            (order.amount * offer.collateral) / offer.amount,
            18,
            targetDecimals
        );
        uint256 value = convertDecimals(
            (order.amount * offer.value) / offer.amount,
            18,
            targetDecimals
        );

        // transfer liquid to seller
        uint256 settleFee = (value * config.feeSettle) / WEI6;
        uint256 totalValue = value + collateral - settleFee;
        if (offer.exToken == address(0)) {
            // by ETH
            (bool success1, ) = order.seller.call{value: totalValue}("");
            (bool success2, ) = config.feeWallet.call{value: settleFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            // by exToken
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.safeTransfer(order.seller, totalValue);
            iexToken.safeTransfer(config.feeWallet, settleFee);
        }

        order.status = STATUS_ORDER_SETTLE_FILLED;

        emit Settle2Steps(orderId, hash, _msgSender());
        emit SettleFilled(orderId, totalValue, settleFee, _msgSender());
    }
    
    /**
    * @param orderIds An array of order IDs to be settled.
    * @param hashes An array of hashes, each corresponding to a transaction in the `orderIds` array for verification.
    */
    function settle2StepsBatch(
        uint256[] memory orderIds,
        bytes32[] memory hashes
    ) external {
        require(orderIds.length == hashes.length, "Invalid Input");
        for (uint256 i = 0; i < orderIds.length; i++) {
            settle2Steps(orderIds[i], hashes[i]);
        }
    }

    /////////////////////////
    ////// USER ACTION //////
    /////////////////////////

    /**
    * @param offerType Specifies the type of offer: 1 for buy, 2 for sell.
    * @param tokenId The unique identifier of the token for which the offer is being made.
    * @param amount The amount of tokens being offered for buy/sell.
    * @param value The total value (in exchange token or ETH) that the offerer is willing to pay or receive.
    * @param exToken The token address against which the offer is being made. Address(0) if the offer is in ETH.
    * @param fullMatch A boolean indicating if the offer must be fully matched (true) or can be partially filled (false).
    */
    function newOffer(
        uint8 offerType,
        bytes32 tokenId,
        uint256 amount,
        uint256 value,
        address exToken,
        bool fullMatch
    ) external nonReentrant {
        Token storage token = tokens[tokenId];
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid Token");
        require(
            exToken != address(0) && acceptedTokens[exToken],
            "Invalid Offer Token"
        );
        require(amount > 0 && value > 0, "Invalid Amount or Value");

        uint8 targetDecimals = IERC20Metadata(exToken).decimals();
        uint256 adjustedValue = convertDecimalsCeil(value, 18, targetDecimals);
        uint256 collateral = (value * config.pledgeRate) / WEI6;
        uint256 adjustedCollateral = convertDecimalsCeil(collateral, 18, targetDecimals);

        uint256 _transferAmount = offerType == OFFER_BUY ? adjustedValue : adjustedCollateral;
        IERC20 iexToken = IERC20(exToken);
        iexToken.safeTransferFrom(_msgSender(), address(this), _transferAmount);
        
        // create new offer
        _newOffer(
            offerType,
            tokenId,
            exToken,
            amount,
            value,
            collateral,
            fullMatch
        );
    }

    /**
    * @param offerType, tokenId, amount, value, and fullMatch parameters have the same definitions as in `newOffer`.
    */
    function newOfferETH(
        uint8 offerType,
        bytes32 tokenId,
        uint256 amount,
        uint256 value,
        bool fullMatch
    ) external payable nonReentrant {
        Token storage token = tokens[tokenId];
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid Token");
        require(amount > 0 && value > 0, "Invalid Amount or Value");
        // collateral
        uint256 collateral = (value * config.pledgeRate) / WEI6;

        uint256 _ethAmount = offerType == OFFER_BUY ? value : collateral;
        require(_ethAmount <= msg.value, "Insufficient Funds");
        // (PMA-1)If the sent ETH is more than required, refund the excess
        if (msg.value > _ethAmount) {
            uint256 excessAmount = msg.value - _ethAmount;
            (bool refundSuccess, ) = msg.sender.call{value: excessAmount}("");
            require(refundSuccess, "Refund of excess ETH failed");
        }
        // create new offer
        _newOffer(
            offerType,
            tokenId,
            address(0),
            amount,
            value,
            collateral,
            fullMatch
        );
    }

    /**
    * @param offerId The ID of the offer being filled.
    * @param amount The amount of the offer the filler wishes to fulfill. Must not exceed the available amount in the offer.
    */
    function fillOffer(uint256 offerId, uint256 amount) external nonReentrant {
        
        Offer storage offer = offers[offerId];
        Token storage token = tokens[offer.tokenId];

        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid token Status");
        require(amount > 0, "Invalid Amount");
        require(
            offer.amount - offer.filledAmount >= amount,
            "Insufficient Allocations"
        );
        require(
            offer.fullMatch == false || offer.amount == amount,
            "FullMatch required"
        );
        require(offer.exToken != address(0), "Invalid Offer Token");

        // transfer value or collateral
        IERC20 iexToken = IERC20(offer.exToken);
        uint256 _transferAmount;
        address buyer;
        address seller;
        uint8 targetDecimals = IERC20Metadata(offer.exToken).decimals();
        if (offer.offerType == OFFER_BUY) {
            uint256 collateralAmount = (offer.collateral * amount) / offer.amount;
            _transferAmount = convertDecimalsCeil(collateralAmount, 18, targetDecimals);
            buyer = offer.offeredBy;
            seller = _msgSender();
        } else {
            uint256 valueAmount = (offer.value * amount) / offer.amount;
            _transferAmount = convertDecimalsCeil(valueAmount, 18, targetDecimals);
            buyer = _msgSender();
            seller = offer.offeredBy;
        }
        iexToken.safeTransferFrom(_msgSender(), address(this), _transferAmount);

        // new order
        _fillOffer(offerId, amount, buyer, seller);
    }

    /**
    * @param offerId The ID of the offer to be filled.
    * @param amount The amount of the offer that the user wishes to fulfill.
    */
    function fillOfferETH(
        uint256 offerId,
        uint256 amount
    ) external payable nonReentrant {
        
        Offer storage offer = offers[offerId];
        Token storage token = tokens[offer.tokenId];

        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
        require(token.status == STATUS_TOKEN_ACTIVE, "Invalid token Status");
        require(amount > 0, "Invalid Amount");
        require(
            offer.amount - offer.filledAmount >= amount,
            "Insufficient Allocations"
        );
        require(
            offer.fullMatch == false || offer.amount == amount,
            "FullMatch required"
        );
        require(offer.exToken == address(0), "Invalid Offer Token");

        // transfer value or collecteral
        uint256 _ethAmount;
        address buyer;
        address seller;
        if (offer.offerType == OFFER_BUY) {
            _ethAmount = (offer.collateral * amount) / offer.amount;
            buyer = offer.offeredBy;
            seller = _msgSender();
        } else {
            _ethAmount = (offer.value * amount) / offer.amount;
            buyer = _msgSender();
            seller = offer.offeredBy;
        }
        require(msg.value >= _ethAmount, "Insufficient Funds");

        // (PMA-1)Refund excess ETH
        if (msg.value > _ethAmount) {
            uint256 excessAmount = msg.value - _ethAmount;
            (bool refundSuccess, ) = msg.sender.call{value: excessAmount}("");
            require(refundSuccess, "Refund of excess ETH failed");
        }

        // new order
        _fillOffer(offerId, amount, buyer, seller);
    }

    /**
    * @param offerId The ID of the offer to be cancelled.
    */
    function cancelOffer(uint256 offerId) public nonReentrant {
        
        Offer storage offer = offers[offerId];

        require(offer.offeredBy == _msgSender(), "Offer Owner Only");
        require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");

        uint256 refundAmount = offer.amount - offer.filledAmount;
        require(refundAmount > 0, "Insufficient Allocations");

        // calculate refund
        uint8 targetDecimals;
        if (offer.exToken == address(0)) {
            targetDecimals = 18;
        } else {
            targetDecimals = IERC20Metadata(offer.exToken).decimals();
        }

        uint256 refundValue;
        if (offer.offerType == OFFER_BUY) {
            refundValue = convertDecimals(
                (refundAmount * offer.value) / offer.amount,
                18, // source decimals
                targetDecimals
            );
        } else {
            refundValue = convertDecimals(
                (refundAmount * offer.collateral) / offer.amount,
                18, // source decimals
                targetDecimals
            );
        }
        uint256 refundFee = (refundValue * config.feeRefund) / WEI6;
        refundValue -= refundFee;

        // refund
        if (offer.exToken == address(0)) {
            // refund ETH
            (bool success1, ) = offer.offeredBy.call{value: refundValue}("");
            (bool success2, ) = config.feeWallet.call{value: refundFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.safeTransfer(offer.offeredBy, refundValue);
            iexToken.safeTransfer(config.feeWallet, refundFee);
        }

        offer.status = STATUS_OFFER_CANCELLED;
        emit CancelOffer(offerId, refundValue, refundFee, _msgSender());
    }   

    /**
    * @param orderId The ID of the order to settle.
    */
    function settleFilled(uint256 orderId) public nonReentrant {
        
        Order storage order = orders[orderId];
        Offer storage offer = offers[order.offerId];
        Token storage token = tokens[offer.tokenId];

        // check condition
        require(token.status == STATUS_TOKEN_SETTLE, "Invalid Status");
        require(
            token.token != address(0) && token.settleRate > 0,
            "Token Not Set"
        );
        //PMA-5
        require(
            token.settleTime > 0,
            "Settling Time Not Started"
        );
        require(order.seller == _msgSender(), "Seller Only");
        require(order.status == STATUS_ORDER_OPEN, "Invalid Order Status");

        uint8 exTokenDecimals;
        if (offer.exToken == address(0)) {
            exTokenDecimals = 18;
        } else {
            exTokenDecimals = IERC20Metadata(offer.exToken).decimals();
        }

        uint256 collateral = convertDecimals(
            (order.amount * offer.collateral) / offer.amount,
            18,
            exTokenDecimals
        );
        uint256 value = convertDecimals(
            (order.amount * offer.value) / offer.amount,
            18,
            exTokenDecimals
        );

        // transfer token to buyer
        IERC20 iToken = IERC20(token.token);
        uint8 tokenDecimals = IERC20Metadata(token.token).decimals();
        // calculate token amount
        uint256 tokenAmount = convertDecimals(
            (order.amount * token.settleRate) / WEI6,
            18,
            tokenDecimals
        );
        uint256 tokenAmountFee = (tokenAmount * config.feeSettle) / WEI6;
        // transfer order fee in token to fee wallet
        iToken.safeTransferFrom(
            order.seller,
            config.feeWallet,
            tokenAmountFee
        );
        // transfer token after fee to buyer
        iToken.safeTransferFrom(
            order.seller,
            order.buyer,
            tokenAmount - tokenAmountFee
        );

        // transfer liquid to seller
        uint256 settleFee = (value * config.feeSettle) / WEI6;
        uint256 totalValue = value + collateral - settleFee;
        if (offer.exToken == address(0)) {
            // by ETH
            (bool success1, ) = order.seller.call{value: totalValue}("");
            (bool success2, ) = config.feeWallet.call{value: settleFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            // by exToken
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.safeTransfer(order.seller, totalValue);
            iexToken.safeTransfer(config.feeWallet, settleFee);
        }

        order.status = STATUS_ORDER_SETTLE_FILLED;

        emit SettleFilled(orderId, totalValue, settleFee, _msgSender());
    }

    /**
    * @param orderId The ID of the order to cancel settlement for.
    */
    function settleCancelled(uint256 orderId) public nonReentrant {
        
        Order storage order = orders[orderId];
        Offer storage offer = offers[order.offerId];
        Token storage token = tokens[offer.tokenId];

        // check condition
        require(token.status == STATUS_TOKEN_SETTLE, "Invalid Status");
        require(
            block.timestamp > token.settleTime + token.settleDuration,
            "Settling Time Not Ended Yet"
        );
        require(order.status == STATUS_ORDER_OPEN, "Invalid Order Status");
        require(
            order.buyer == _msgSender() || hasRole(OPERATOR_ROLE, _msgSender()),
            "Buyer or Operator Only"
        );

        uint8 exTokenDecimals;
        if (offer.exToken == address(0)) {
            exTokenDecimals = 18;
        } else {
            exTokenDecimals = IERC20Metadata(offer.exToken).decimals();
        }

        uint256 collateral = convertDecimals(
            (order.amount * offer.collateral) / offer.amount,
            18,
            exTokenDecimals
        );
        uint256 value = convertDecimals(
            (order.amount * offer.value) / offer.amount,
            18,
            exTokenDecimals
        );

        // transfer liquid to buyer
        uint256 settleFee = (collateral * config.feeSettle * 2) / WEI6;
        uint256 totalValue = value + collateral - settleFee;
        if (offer.exToken == address(0)) {
            // by ETH
            (bool success1, ) = order.buyer.call{value: totalValue}("");
            (bool success2, ) = config.feeWallet.call{value: settleFee}("");
            require(success1 && success2, "Transfer Funds Fail");
        } else {
            // by exToken
            IERC20 iexToken = IERC20(offer.exToken);
            iexToken.safeTransfer(order.buyer, totalValue);
            iexToken.safeTransfer(config.feeWallet, settleFee);
        }

        order.status = STATUS_ORDER_SETTLE_CANCELLED;

        emit SettleCancelled(orderId, totalValue, settleFee, _msgSender());
    }

    /**
    * @param orderIds An array of order IDs to be forcibly cancelled.
    */
    function forceCancelOrders(uint256[] memory orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            forceCancelOrder(orderIds[i]);
        }
    }

    /**
    * @param offerIds An array of offer IDs that the user wishes to cancel.
    */
    function cancelOffers(uint256[] memory offerIds) external {
        for (uint256 i = 0; i < offerIds.length; i++) {
            cancelOffer(offerIds[i]);
        }
    }

    /**
    * @param orderIds An array of order IDs to be settled.
    */
    function settleFilleds(uint256[] memory orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            settleFilled(orderIds[i]);
        }
    }

    /**
    * @param orderIds An array of order IDs for which settlement is to be cancelled.
    */
    function settleCancelleds(uint256[] memory orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            settleCancelled(orderIds[i]);
        }
    }

    /**
    * @param offerIds An array of offer IDs to be filled.
    * @param amounts An array of amounts, each corresponding to an offer in the `offerIds` array.
    */
    function fillOffers(uint256[] memory offerIds, uint256[] memory amounts) external nonReentrant {
        require(offerIds.length == amounts.length, "Invalid Input");
        for (uint256 i = 0; i < offerIds.length; i++) {
            uint256 offerId = offerIds[i];
            uint256 amount = amounts[i];
            Offer storage offer = offers[offerId];
            Token storage token = tokens[offer.tokenId];

            require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
            require(token.status == STATUS_TOKEN_ACTIVE, "Invalid token Status");
            require(amount > 0, "Invalid Amount");
            require(
                offer.amount - offer.filledAmount >= amount,
                "Insufficient Allocations"
            );
            require(
                offer.fullMatch == false || offer.amount == amount,
                "FullMatch required"
            );
            require(offer.exToken != address(0), "Invalid Offer Token");

            // transfer value or collateral
            IERC20 iexToken = IERC20(offer.exToken);
            uint256 _transferAmount;
            address buyer;
            address seller;
            uint8 targetDecimals = IERC20Metadata(offer.exToken).decimals();
            if (offer.offerType == OFFER_BUY) {
                uint256 collateralAmount = (offer.collateral * amount) / offer.amount;
                _transferAmount = convertDecimalsCeil(collateralAmount, 18, targetDecimals);
                buyer = offer.offeredBy;
                seller = _msgSender();
            } else {
                uint256 valueAmount = (offer.value * amount) / offer.amount;
                _transferAmount = convertDecimalsCeil(valueAmount, 18, targetDecimals);
                buyer = _msgSender();
                seller = offer.offeredBy;
            }
            iexToken.safeTransferFrom(_msgSender(), address(this), _transferAmount);
            // new order
            _fillOffer(offerId, amount, buyer, seller);
        }
    }

    /**
    * @param offerIds An array of offer IDs to be filled.
    * @param amounts An array of amounts, each corresponding to an offer in the `offerIds` array.
    */
    function fillOffersETH(uint256[] memory offerIds, uint256[] memory amounts) external payable nonReentrant {
        require(offerIds.length == amounts.length, "Invalid Input");
        uint256 totalEthAmount = 0;
        for (uint256 i = 0; i < offerIds.length; i++) {
            uint256 offerId = offerIds[i];
            uint256 amount = amounts[i];
            Offer storage offer = offers[offerId];
            Token storage token = tokens[offer.tokenId];

            require(offer.status == STATUS_OFFER_OPEN, "Invalid Offer Status");
            require(token.status == STATUS_TOKEN_ACTIVE, "Invalid token Status");
            require(amount > 0, "Invalid Amount");
            require(
                offer.amount - offer.filledAmount >= amount,
                "Insufficient Allocations"
            );
            require(
                offer.fullMatch == false || offer.amount == amount,
                "FullMatch required"
            );
            require(offer.exToken == address(0), "Invalid Offer Token");
            uint256 _ethAmount;
            if (offer.offerType == OFFER_BUY) {
                _ethAmount = (offer.collateral * amount) / offer.amount;
            } else {
                _ethAmount = (offer.value * amount) / offer.amount;
            }
            totalEthAmount += _ethAmount;
            // Assuming _fillOffer handles the logic for each offer correctly
            _fillOffer(offerId, amount, offer.offeredBy, _msgSender());
        }
        require(msg.value >= totalEthAmount, "Insufficient Funds");

        // (PMA-1)Refund excess ETH
        if (msg.value > totalEthAmount) {
            uint256 excessAmount = msg.value - totalEthAmount;
            (bool refundSuccess, ) = msg.sender.call{value: excessAmount}("");
            require(refundSuccess, "Refund of excess ETH failed");
        }
    }

    ///////////////////////////
    ///////// SETTER //////////
    ///////////////////////////

    /**
    * @param feeWallet_ The address of the wallet where transaction fees are collected.
    * @param feeSettle_ The fee percentage charged upon the successful settlement of an order.
    * @param feeRefund_ The fee percentage charged when an offer is cancelled and funds are refunded.
    * @param pledgeRate_ The required collateral percentage for creating sell offers.
    */
    function updateConfig(
        address feeWallet_,
        uint256 feeSettle_,
        uint256 feeRefund_,
        uint256 pledgeRate_
    ) external onlyRole(OPERATOR_ROLE) {    
        require(feeWallet_ != address(0), "Invalid Address");
        require(feeSettle_ <= WEI6 / 10, "Settle Fee <= 10%");
        require(feeRefund_ <= WEI6 / 10, "Cancel Fee <= 10%");
        //PMA-2 limit pledge rate from 1% to 100%.
        require(pledgeRate_ >= WEI6 / 100 && pledgeRate_ <= WEI6, "Pledge Rate out of range");
        emit UpdateConfig(
            config.feeWallet,
            config.feeSettle,
            config.feeRefund,
            config.pledgeRate,
            feeWallet_,
            feeSettle_,
            feeRefund_,
            pledgeRate_
        );
        // update
        config.feeWallet = feeWallet_;
        config.feeSettle = feeSettle_;
        config.feeRefund = feeRefund_;
        config.pledgeRate = pledgeRate_;
    }

    /**
    * @param tokenAddresses An array of token addresses to be updated.
    * @param isAccepted Boolean flag indicating whether the tokens should be accepted (true) or not (false).
    */
    function setAcceptedTokens(
        address[] memory tokenAddresses,
        bool isAccepted
    ) external onlyRole(OPERATOR_ROLE) {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            acceptedTokens[tokenAddresses[i]] = isAccepted;
        }
        emit UpdateAcceptedTokens(tokenAddresses, isAccepted);
    }

    ///////////////////////////
    ///////// GETTER //////////
    ///////////////////////////

    /**
    * @param offerId The unique identifier of the offer.
    */
    function offerAmount(uint256 offerId) external view returns (uint256) {       
        return offers[offerId].amount;
    }
    /**
    * @param offerId The unique identifier of the offer.
    */
    function offerAmountAvailable(
        uint256 offerId
    ) external view returns (uint256) {        
        return offers[offerId].amount - offers[offerId].filledAmount;
    }
    /**
    * @param offerId The unique identifier of the offer.
    */
    function offerValue(uint256 offerId) external view returns (uint256) {       
        return offers[offerId].value;
    }
    /**
    * @param offerId The unique identifier of the offer.
    */
    function offerExToken(uint256 offerId) external view returns (address) {       
        return offers[offerId].exToken;
    }

    /**
    * @param offerId The unique identifier of the offer.
    */
    function isBuyOffer(uint256 offerId) external view returns (bool) {      
        return offers[offerId].offerType == OFFER_BUY;
    }
    /**
    * @param offerId The unique identifier of the offer.
    */
    function isSellOffer(uint256 offerId) external view returns (bool) {       
        return offers[offerId].offerType == OFFER_SELL;
    }
    /**
    * @param offerId The unique identifier of the offer.
    */
    function offerStatus(uint256 offerId) external view returns (uint256) {       
        return offers[offerId].status;
    }

    /**
    @param orderId The unique identifier of the order.
    */
    function orderStatus(uint256 orderId) external view returns (uint256) {       
        return orders[orderId].status;
    }
    /**
    * @param id The unique identifier of the token, typically derived from its properties or a hash of its metadata.
    */
    function tokensInfo(bytes32 id) external view returns (Token memory tokenInfo) {
        return tokens[id];
    }
    /**
    * @param id The unique identifier of the offer.
    */
    function offersInfo(uint256 id) external view returns (Offer memory) {        
        return offers[id];
    }
    /**
    * @param id The unique identifier of the order.
    */
    function ordersInfo(uint256 id) external view returns (Order memory) {        
        return orders[id];
    }
    /**
    * Accesses the current configuration settings of the platform, including fees and the pledge rate.
    */
    function configInfo() external view returns (Config memory) {       
        return config;
    }
    /**
    * Checks whether a specific token is accepted for trading on the platform.
    * @param token The address of the token in question.
    */
    function isAcceptedToken(address token) external view returns (bool) {       
        return acceptedTokens[token];
    }
    /**
    * Retrieves the identifier of the last offer made in the market, indicative of the total number of offers created.
    */
    function lastOfferIdInfo() external view returns (uint256) {   
        return lastOfferId;
    }
    /**
    * Returns the identifier of the last order processed in the system, serving as a measure of the platform's trading volume.
    */
    function lastOrderIdInfo() external view returns (uint256) {        
        return lastOrderId;
    }

    ///////////////////////////
    //////// INTERNAL /////////
    ///////////////////////////

    /**
    * @param offerType Specifies whether it's a buy or sell offer.
    * @param tokenId The unique identifier for the token being traded.
    * @param exToken The address of the exchange token or ETH used for the trade.
    * @param amount The amount of the token being offered.
    * @param value The total value (in exToken or ETH) of the offer.
    * @param collateral The required collateral for the offer, applicable for sell offers.
    * @param fullMatch Indicates whether the offer requires to be filled in its entirety.
    */   
    function _newOffer(
        uint8 offerType,
        bytes32 tokenId,
        address exToken,
        uint256 amount,
        uint256 value,
        uint256 collateral,
        bool fullMatch
    ) internal {
        
        // create new offer
        offers[++lastOfferId] = Offer(
            offerType,
            tokenId,
            exToken,
            amount,
            value,
            collateral,
            0,
            STATUS_OFFER_OPEN,
            _msgSender(),
            fullMatch
        );

        emit NewOffer(
            lastOfferId,
            offerType,
            tokenId,
            exToken,
            amount,
            value,
            collateral,
            fullMatch,
            _msgSender()
        );
    }
    /**
    * @param offerId The ID of the offer being filled.
    * @param amount The amount of the offer that is being fulfilled.
    * @param buyer The address of the buyer in the transaction.
    * @param seller The address of the seller.
    */
    function _fillOffer(
        uint256 offerId,
        uint256 amount,
        address buyer,
        address seller
    ) internal {
        
        Offer storage offer = offers[offerId];
        // new order
        orders[++lastOrderId] = Order(
            offerId,
            amount,
            seller,
            buyer,
            STATUS_ORDER_OPEN
        );

        // check if offer is fullfilled
        offer.filledAmount += amount;
        if (offer.filledAmount == offer.amount) {
            offer.status = STATUS_OFFER_FILLED;
            emit CloseOffer(offerId, 0);
        }

        emit NewOrder(lastOrderId, offerId, amount, seller, buyer);
    }


     /**
      * @dev Withdraws stuck tokens from the contract. Only addresses with the UPGRADER_ROLE role can call this function.
      * @param _token The address of the token to withdraw.
      * @param _to The address to receive the withdrawn tokens.
      * @notice Use this function with caution to avoid accidentally moving funds.
      */
     function withdrawStuckToken(
         address _token,
         address _to
     ) external onlyRole(OPERATOR_ROLE) {
         
         require(
             _token != address(0) && !acceptedTokens[_token],
             "Invalid Token Address"
         );
         uint256 _contractBalance = IERC20(_token).balanceOf(address(this));
         IERC20(_token).safeTransfer(_to, _contractBalance);
     }
}
