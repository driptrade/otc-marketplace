// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    AccessControlEnumerableUpgradeable
} from '@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {
    AcceptBidParams,
    BidType,
    BuyItemParams,
    CancelBidParams,
    CancelListingParams,
    CreateOrUpdateListingParams
} from './MarketplaceStructs.sol';

/**
 * @title Drip.Trade marketplace contract
 * @notice The Drip.Trade contract supports NFT trading on Hyperliquid.
 *
 * The contract allows enforcement of royalties onchain, and supports multi-token
 * marketplace operations in a single transaction for almost all functionalities.
 *
 * This contract is based on the Trove marketplace contract (TreasureProject/treasure-marketplace-contracts)
 * at commit fc3b17f50e08b65426193e8e13893d5644b42569.
 */
contract OTCMarketplace is AccessControlEnumerableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct ListingOrBid {
        /**
         * @dev number of tokens for sale or requested
         *
         * If ERC-721 token is active for sale, quantity should be 1. For bids, quantity for ERC-721 can
         * be greater than 1 (in order to support collection bids).
         */
        uint64 quantity;
        /**
         * @dev price per token sold
         *
         * Sale price equals this times quantity purchased. For bids, price offered per item.
         */
        uint128 pricePerItem;
        /**
         * @dev timestamp after which the listing/bid is invalid
         */
        uint64 expirationTime;
        /**
         * @dev the payment token for this listing/bid.
         */
        address paymentTokenAddress;
    }

    struct Token {
        address nftAddress;
        uint256 tokenId;
    }

    struct Order {
        uint16 orderId;
        OrderStatus status;
        address nftAddress;
        uint256 tokenId;
        uint128 pricePerItem;
        uint64 quantity;
        address buyer;
        address seller;
        address paymentToken;
        address collateralToken;
    }

    struct OrderParams {
        uint16 orderId;
        address nftAddress;
        uint256 tokenId;
        uint128 pricePerItem;
        uint64 quantity;
        address buyer;
        address seller;
        address paymentToken;
        address collateralToken;
    }

    enum OrderStatus {
        Unfulfilled,
        Fulfilled,
        Reverted,
        Forfeited
    }

    enum CollectionApprovalStatus {
        NOT_APPROVED,
        ERC_721_APPROVED,
        ERC_1155_APPROVED
    }

    /**
     * @notice ERC165 interface signatures
     */
    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    /**
     * @notice MARKETPLACE_ADMIN_ROLE role hash
     */
    bytes32 private constant MARKETPLACE_ADMIN_ROLE = keccak256('MARKETPLACE_ADMIN_ROLE');

    /**
     * @notice the denominator for fraction calculations
     *
     * This is the number of parts allowed in 100%.
     */
    uint256 private constant BASIS_POINTS = 10000;

    /**
     * @notice the minimum price for bids and asks (1e18)
     */
    uint256 private constant MIN_PRICE = 1_000_000_000_000_000_000;

    /**
     * @notice the marketplace fee (in basis points) for each sale for collections without creator fees
     */
    uint256 internal buyerFee;

    /**
     * @notice the marketplace fee (in basis points) for each sale for collections with creator fees set
     */
    uint256 internal sellerFee;

    /**
     * @notice address that receives marketplace fees
     */
    address internal feeRecipient;

    uint64 internal fulfillmentStartTimestamp;

    uint64 internal fulfillmentDuration;

    uint16 public numOrders;

    /**
     * @notice collections which have been approved to be sold on the marketplace, maps: nftAddress => status
     */
    mapping(address => CollectionApprovalStatus) public collectionApprovals;

    /**
     * @notice mapping for listings, maps: nftAddress => tokenId => seller
     */
    mapping(address => mapping(uint256 => mapping(address => ListingOrBid))) public listings;

    /**
     * @notice mapping for collection level bids (721 only): nftAddress => bidder
     */
    mapping(address => mapping(address => ListingOrBid)) public collectionBids;

    /**
     * @notice mapping for allowed stablecoin payment tokens: stablecoin token address => `true` if allowed
     */
    mapping(address => bool) public allowedStablecoins;

    mapping(address => mapping(uint256 => bool)) public tokenHasSold;

    /**
     * @notice mapping for allowed stablecoin payment tokens: stablecoin token address => `true` if allowed
     */
    mapping(address => mapping(uint256 => Token)) public tokenMappings;

    mapping(uint16 orderIndex => Order) public orders;

    mapping(address => mapping(uint256 => bool)) internal orderedTokenIds;

    /**
     * @notice The marketplace fees were updated
     * @param  buyerFee  new fee amount (in units of basis points) paid by buyer
     * @param  sellerFee new fee amount (in units of basis points) paid by seller
     */
    event UpdateFees(uint256 buyerFee, uint256 sellerFee);

    /**
     * @notice The fee recipient was updated
     * @param  feeRecipient  the new recipient to get fees
     */
    event UpdateFeeRecipient(address feeRecipient);

    /**
     * @notice The approval status for a collection was updated
     * @param  nftAddress    the collection contract
     * @param  status        the new status
     * @param  paymentToken  the token that will be used for payments for this collection
     */
    event ApprovalStatusUpdated(address nftAddress, CollectionApprovalStatus status, address paymentToken);

    /**
     * @notice A collection bid was created or updated
     * @param  bidder         the bidder for the tokens
     * @param  nftAddress     which token contract holds the wanted tokens
     * @param  quantity       how many of this collection's tokens are wanted
     * @param  pricePerItem   the price (in units of the paymentToken) for each token wanted
     * @param  expirationTime UNIX timestamp after when this bid expires
     * @param  paymentToken   the token used to pay
     */
    event CollectionBidCreatedOrUpdated(
        address bidder,
        address nftAddress,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    /**
     * @notice A token bid was cancelled
     * @param  bidder         the bidder for the token
     * @param  nftAddress     which token contract holds the bidded token
     */
    event CollectionBidCancelled(address bidder, address nftAddress);

    /**
     * @notice A bid was accepted
     * @param  seller         the user who accepted the bid
     * @param  bidder         the bidder for the tokens
     * @param  nftAddress     which token contract holds the exchanged tokens
     * @param  tokenId        the identifier for the exchanged token
     * @param  quantity       the number of tokens exchanged
     * @param  pricePerItem   the price (in units of the paymentToken) for each token exchanged
     * @param  paymentToken   the token used to pay
     * @param  bidType        whether the bid was a token bid (0) or collection bid (1)
     */
    event BidAccepted(
        address seller,
        address bidder,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        address paymentToken,
        BidType bidType
    );

    /**
     * @notice An item was listed for sale
     * @param  seller         the offeror of the item
     * @param  nftAddress     which token contract holds the offered token
     * @param  tokenId        the identifier for the offered token
     * @param  quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
     * @param  pricePerItem   the price (in units of the paymentToken) for each token offered
     * @param  expirationTime UNIX timestamp after when this listing expires
     * @param  paymentToken   the token used to list this item
     */
    event ItemListed(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    /**
     * @notice An item listing was updated
     * @param  seller         the offeror of the item
     * @param  nftAddress     which token contract holds the offered token
     * @param  tokenId        the identifier for the offered token
     * @param  quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
     * @param  pricePerItem   the price (in units of the paymentToken) for each token offered
     * @param  expirationTime UNIX timestamp after when this listing expires
     * @param  paymentToken   the token used to list this item
     */
    event ItemUpdated(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    /**
     * @notice An item is no longer listed for sale
     * @param  seller     former offeror of the item
     * @param  nftAddress which token contract holds the formerly offered token
     * @param  tokenId    the identifier for the formerly offered token
     */
    event ItemCanceled(address indexed seller, address indexed nftAddress, uint256 indexed tokenId);

    /**
     * @notice A listed item was sold
     * @param  seller       the offeror of the item
     * @param  buyer        the buyer of the item
     * @param  nftAddress   which token contract holds the sold token
     * @param  tokenId      the identifier for the sold token
     * @param  quantity     how many of this token identifier where sold (or 1 for a ERC-721 token)
     * @param  pricePerItem the price (in units of the paymentToken) for each token sold
     * @param  paymentToken the payment token that was used to pay for this item
     */
    event ItemSold(
        address seller,
        address buyer,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        address paymentToken
    );

    event OrderReverted(uint16 orderId);

    event OrderFulfilled(uint16 orderId);

    event OrderForfeited(uint16 orderId);

    /**
     * @dev Collection had no approval status found in `collectionApprovals`.
     */
    error MarketplaceCollectionNotApprovedForTrading(address nftAddress);

    error MarketplaceCollectionDoesNotSupportInterface(address nftAddress);

    error MarketplaceFeesTooHigh(uint256 feeRequested, uint256 feeLimit);

    error MarketplaceAddressInvalid(address addr);

    error MarketplaceBadQuantity(uint64 qty);

    error MarketplaceExpirationInvalid(uint64 expirationTime);

    error MarketplacePriceLessThanMinPrice(uint256 price);

    error MarketplacePriceInvalidPrecision(uint256 price);

    /**
     * @dev Collection bids on ERC1155 collections are not allowed.
     */
    error MarketplaceCollectionBidOnErc1155(address nftAddress);

    error MarketplaceCannotFulfillOwnListingOrBid();

    error MarketplaceListingOrBidAlreadyExpired(uint64 expirationTime);

    error MarketplaceListingOrBidQuantityIsZero();

    error MarketplaceListingOrBidNotEnoughQuantity(uint64 qty);

    error MarketplaceListingOrBidPriceIsZero();

    error MarketplaceListingOrBidPriceDoesNotMatch(uint128 price);

    error MarketplaceOwnerDoesNotHoldEnoughQuantity(address nftAddress, uint256 tokenId, uint256 balance);

    error MarketplaceNotEnoughPaymentTokens(uint256 allowance, uint256 balance, uint256 needed);

    error MarketplaceUnauthorizedOrderModification();

    error MarketplaceCannotFulfillBeforeGenesis(address nftAddress, uint256 tokenId);

    error MarketplaceModificationForUnfulfilledOrdersOnly(uint16 orderId, OrderStatus status);

    error MarketplaceDoesNotMatchOrder(uint16 orderId);

    error MarketplaceTokenAlreadySold(address nftAddress, uint256 tokenId);

    error MarketplaceDisallowedPaymentToken(address paymentToken);

    error MarketplaceFulfillOrdersNotAllowed();

    error MarketplaceForfeitOrdersNotAllowed();

    error MarketplaceRevertOrdersNotAllowed();

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() initializer {}

    /**
     * @notice Perform initial contract setup
     * @dev    The initializer modifier ensures this is only called once, the owner should confirm this was properly
     *         performed before publishing this contract address.
     * @param  _initialFee          marketplace fees, in basis points
     * @param  _initialFeeRecipient wallet to collet marketplace fees
     * @param  _initialPaymentToken address of the default token that is used for settlement
     */
    function initialize(
        uint256 _initialFee,
        address _initialFeeRecipient,
        IERC20 _initialPaymentToken
    ) external initializer {
        if (address(_initialPaymentToken) == address(0)) {
            revert MarketplaceAddressInvalid(address(_initialPaymentToken));
        }

        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

        _setRoleAdmin(MARKETPLACE_ADMIN_ROLE, MARKETPLACE_ADMIN_ROLE);
        _grantRole(MARKETPLACE_ADMIN_ROLE, msg.sender);

        setFees(_initialFeeRecipient, _initialFee, _initialFee);
    }

    /************************************/
    /* Public Marketplace Functionality */
    /************************************/

    /**
     * @notice Create or update multiple listings. You must first authorize this marketplace with your
     *         item's token contract in order to list.
     * @param  _createOrUpdateListingParamsBatch an array of listing params
     *
     * Listing params:
     * - nftAddress     which token contract holds the offered token
     * - tokenId        the identifier for the offered token
     * - quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
     * - pricePerItem   the price (in units of the paymentToken) for each token offered
     * - expirationTime UNIX timestamp after when this listing expires
     * - paymentToken   the payment token used to pay for this item
     */
    function createOrUpdateListings(
        CreateOrUpdateListingParams[] calldata _createOrUpdateListingParamsBatch
    ) external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < _createOrUpdateListingParamsBatch.length;) {
            CreateOrUpdateListingParams calldata _createOrUpdateListingParams = _createOrUpdateListingParamsBatch[i];
            _createOrUpdateListing(
                _createOrUpdateListingParams.nftAddress,
                _createOrUpdateListingParams.tokenId,
                _createOrUpdateListingParams.quantity,
                _createOrUpdateListingParams.pricePerItem,
                _createOrUpdateListingParams.expirationTime,
                _createOrUpdateListingParams.paymentToken
            );

            unchecked { i += 1; }
        }
    }

    /**
     * @notice Remove multiple listings. This will succeed even if the listings to be cancelled do
     *         not exist.
     * @param  _cancelListingParamsBatch an array of cancel-listing params
     *
     * Cancel-listing params:
     * - nftAddress which token contract holds the listed token
     * - tokenId    the identifier for the listed token
     */
    function cancelListings(CancelListingParams[] calldata _cancelListingParamsBatch) external nonReentrant {
        for (uint256 i = 0; i < _cancelListingParamsBatch.length;) {
            CancelListingParams calldata _cancelListingParams = _cancelListingParamsBatch[i];
            _cancelListing(_cancelListingParams.nftAddress, _cancelListingParams.tokenId, _msgSender());

            unchecked { i += 1; }
        }
    }

    /**
     * @notice Remove multiple bids. This will succeed even if the bids to be cancelled do not
     *         exist.
     * @param  _cancelBidParamsBatch an array of cancel-bid params
     *
     * Cancel-bid params:
     * - bidType    whether the bid was a token bid (0) or collection bid (1)
     * - nftAddress which token contract holds the offered token
     * - tokenId    the identifier for the offered token
     */
    function cancelBids(CancelBidParams[] calldata _cancelBidParamsBatch) external nonReentrant {
        for (uint256 i = 0; i < _cancelBidParamsBatch.length;) {
            CancelBidParams calldata _cancelBidParams = _cancelBidParamsBatch[i];
            if (_cancelBidParams.bidType == BidType.COLLECTION) {
                _cancelCollectionBid(_cancelBidParams.nftAddress, _msgSender());
            }

            unchecked { i += 1; }
        }
    }

    /**
     * @notice Create or update a collection bid. You must first authorize this marketplace with your
     *         payment token's ERC20 contract.
     * @param _nftAddress     which token contract holds the wanted token
     * @param _quantity       how many of this token identifier are wanted
     * @param _pricePerItem   the price (in units of the paymentToken) for each token wanted
     * @param _expirationTime UNIX timestamp after when this listing expires
     * @param _paymentToken   the payment token used to pay for the wanted token
     */
    function createOrUpdateCollectionBid(
        address _nftAddress,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) external nonReentrant whenNotPaused {
        if (collectionApprovals[_nftAddress] == CollectionApprovalStatus.ERC_721_APPROVED) {
            if (_quantity == 0) {
                revert MarketplaceBadQuantity(_quantity);
            }
        } else if (collectionApprovals[_nftAddress] == CollectionApprovalStatus.ERC_1155_APPROVED) {
            revert MarketplaceCollectionBidOnErc1155(_nftAddress);
        } else {
            revert MarketplaceCollectionNotApprovedForTrading(_nftAddress);
        }

        _createBidWithoutEvent(
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken,
            collectionBids[_nftAddress][_msgSender()]
        );

        emit CollectionBidCreatedOrUpdated(
            _msgSender(),
            _nftAddress,
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken
        );
    }

    /**
     * @notice Accepts multiple bids. The accepted bids can be mix of token bids, collection, and
     *         multi-token bids. You must first authorize this marketplace with your items' token
     *         contracts in order to accept.
     *
     *         If the user has a listing for the exchanged token, the listing is automatically
     *         cancelled.
     * @param  _acceptBidParamsBatch an array of advanced accept-bid params
     */
    function acceptBids(AcceptBidParams[] calldata _acceptBidParamsBatch) external nonReentrant whenNotPaused {
        _acceptBids(_acceptBidParamsBatch);
    }

    /**
     * @notice Buy multiple listed items. You must authorize this marketplace with your payment
     *         token to complete the buy, or purchase with native token if it is a wnative
     *         collection.
     *
     *         If the user has a token bid on the exchanged token, the token bid is automatically
     *         cancelled.
     * @param  _buyItemParamsBatch an array of buy-item params
     *
     * Buy-item params:
     * - nftAddress      which token contract holds the offered token
     * - tokenId         the identifier for the offered token
     * - owner           the address currently holding the offered token
     * - quantity        how many of this token identifier are wanted (or 1 for a ERC-721 token)
     * - maxPricePerItem the maximum price (in units of the paymentToken) for each token offered
     * - paymentToken    the payment token used to pay for the wanted token
     * - usingNative     indicates if the user is purchasing this item with native token
     */
    function buyItems(BuyItemParams[] calldata _buyItemParamsBatch) external nonReentrant whenNotPaused {
        _buyItems(_buyItemParamsBatch);
    }

    function fulfillOrders(OrderParams[] calldata _orderParams) external nonReentrant whenNotPaused {
        if (fulfillmentStartTimestamp == 0 || fulfillmentStartTimestamp + fulfillmentDuration < block.timestamp) {
            revert MarketplaceFulfillOrdersNotAllowed();
        }

        for (uint256 i = 0; i < _orderParams.length;) {
            _fulfillOrder(_orderParams[i]);

            unchecked { i += 1; }
        }
    }

    function forfeitOrders(OrderParams[] calldata _orderParams) external nonReentrant whenNotPaused {
        // can only forfeit order if contract is not paused and and the timestamp has elapsed
        if (fulfillmentStartTimestamp == 0 || fulfillmentStartTimestamp + fulfillmentDuration < block.timestamp) {
            revert MarketplaceForfeitOrdersNotAllowed();
        }

        for (uint256 i = 0; i < _orderParams.length;) {
            _forfeitOrder(_orderParams[i]);

            unchecked { i += 1; }
        }
    }

    function revertOrders(OrderParams[] calldata _orderParams) external nonReentrant whenPaused {
        // can only revert if contract is paused and there is no fulfillment timestamp set
        if (fulfillmentStartTimestamp > 0) {
            revert MarketplaceRevertOrdersNotAllowed();
        }

        for (uint256 i = 0; i < _orderParams.length;) {
            _revertOrder(_orderParams[i]);

            unchecked { i += 1; }
        }
    }

    /***********************************/
    /* Marketplace Admin Functionality */
    /***********************************/

    function addAllowedStablecoin(address _token) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        allowedStablecoins[_token] = true;
    }

    function removeAllowedStablecoin(address _token) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        allowedStablecoins[_token] = false;
    }

    function setFulfillmentConfigs(uint64 _timestamp, uint64 _duration) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        fulfillmentStartTimestamp = _timestamp;
        fulfillmentDuration = _duration;
    }

    /**
     * @notice Sets a token as an approved kind of NFT or as ineligible for trading
     * @dev    This is callable only by the owner.
     * @param  _nft          address of the NFT to be approved
     * @param  _status       the kind of NFT approved, or NOT_APPROVED to remove approval
     */
    function setCollectionApprovalStatus(
        address _nft,
        CollectionApprovalStatus _status
    ) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        if (_status == CollectionApprovalStatus.ERC_721_APPROVED) {
            if (!IERC165(_nft).supportsInterface(INTERFACE_ID_ERC721)) {
                revert MarketplaceCollectionDoesNotSupportInterface(_nft);
            }
        } else if (_status == CollectionApprovalStatus.ERC_1155_APPROVED) {
            if (!IERC165(_nft).supportsInterface(INTERFACE_ID_ERC1155)) {
                revert MarketplaceCollectionDoesNotSupportInterface(_nft);
            }
        }

        collectionApprovals[_nft] = _status;

        emit ApprovalStatusUpdated(_nft, _status, address(0));
    }

    /**
     * @notice Pauses the marketplace. Users will not be able to create new listings and bids, nor
     *         execute existing listings and bids.
     * @dev    This is callable only by the owner. Canceling listings and bids are still allowed.
     */
    function pause(bool paused) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        paused ? _pause() : _unpause();
    }

    /**
     * @notice Updates the marketplace fee recipient, as well as all fees.
     * @param  _newFeeRecipient the wallet to receive fees
     * @param  _newBuyerFee     the updated marketplace fee, in basis points, paid by the buyer
     * @param  _newSellerFee    the updated marketplace fee, in basis points, paid by the seller
     */
    function setFees(
        address _newFeeRecipient,
        uint256 _newBuyerFee,
        uint256 _newSellerFee
    ) public onlyRole(MARKETPLACE_ADMIN_ROLE) {
        if (_newFeeRecipient == address(0)) {
            revert MarketplaceAddressInvalid(_newFeeRecipient);
        }
        if (_newBuyerFee > BASIS_POINTS) {
            // buyer fee bps cannot exceed 10_000
            revert MarketplaceFeesTooHigh(_newBuyerFee, BASIS_POINTS);
        }
        if (_newSellerFee > BASIS_POINTS) {
            // seller fee bps cannot exceed 10_000
            revert MarketplaceFeesTooHigh(_newSellerFee, BASIS_POINTS);
        }

        feeRecipient = _newFeeRecipient;
        buyerFee = _newBuyerFee;
        sellerFee = _newSellerFee;

        emit UpdateFeeRecipient(_newFeeRecipient);
        emit UpdateFees(_newBuyerFee, _newSellerFee);
    }

    /********************************/
    /* Internal + Private Functions */
    /********************************/

    function _createOrUpdateListing(
        address _nftAddress,
        uint256 _tokenId,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) private {
        bool _existingListing = listings[_nftAddress][_tokenId][_msgSender()].quantity > 0;
        _createListingWithoutEvent(_nftAddress, _tokenId, _quantity, _pricePerItem, _expirationTime, _paymentToken);
        // Keep the events the same as they were before.
        if (_existingListing) {
            emit ItemUpdated(
                _msgSender(),
                _nftAddress,
                _tokenId,
                _quantity,
                _pricePerItem,
                _expirationTime,
                _paymentToken
            );
        } else {
            emit ItemListed(
                _msgSender(),
                _nftAddress,
                _tokenId,
                _quantity,
                _pricePerItem,
                _expirationTime,
                _paymentToken
            );
        }
    }

    /// @notice Performs the listing and does not emit the event
    /// @param  _nftAddress     which token contract holds the offered token
    /// @param  _tokenId        the identifier for the offered token
    /// @param  _quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
    /// @param  _pricePerItem   the price (in units of the paymentToken) for each token offered
    /// @param  _expirationTime UNIX timestamp after when this listing expires
    function _createListingWithoutEvent(
        address _nftAddress,
        uint256 _tokenId,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) private {
        _validateListingOrBidParams(_pricePerItem, _expirationTime);
        _validateTokenIsTradeable(_nftAddress, _tokenId, _quantity);
        _validatePaymentMethod(_quantity, _pricePerItem, _paymentToken);

        // create or update listing
        listings[_nftAddress][_tokenId][_msgSender()] = ListingOrBid(
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken
        );
    }

    function _cancelListing(address _nftAddress, uint256 _tokenId, address _seller) private {
        uint256 _listedQty = listings[_nftAddress][_tokenId][_seller].quantity;

        delete listings[_nftAddress][_tokenId][_seller];

        if (_listedQty > 0) {
            emit ItemCanceled(_seller, _nftAddress, _tokenId);
        }
    }

    function _createBidWithoutEvent(
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken,
        ListingOrBid storage _bid
    ) private {
        _validateListingOrBidParams(_pricePerItem, _expirationTime);
        _validatePaymentMethod(_quantity, _pricePerItem, _paymentToken);

        _bid.quantity = _quantity;
        _bid.pricePerItem = _pricePerItem;
        _bid.expirationTime = _expirationTime;
        _bid.paymentTokenAddress = _paymentToken;
    }

    function _cancelCollectionBid(address _nftAddress, address _bidder) private {
        uint256 _bidQty = collectionBids[_nftAddress][_bidder].quantity;

        delete collectionBids[_nftAddress][_bidder];

        if (_bidQty > 0) {
            emit CollectionBidCancelled(_bidder, _nftAddress);
        }
    }

    function _acceptBids(AcceptBidParams[] memory _acceptBidParamsBatch) private {
        for (uint256 i = 0; i < _acceptBidParamsBatch.length;) {
            AcceptBidParams memory _params = _acceptBidParamsBatch[i];
            (address _storedPaymentToken, uint128 _storedPricePerItem) = _validateAndProcessBid(_params);
            _acceptBid(_params, _storedPaymentToken, _storedPricePerItem);

            unchecked { i += 1; }
        }
    }

    /// @return the price of the stored bid
    function _validateAndProcessBid(AcceptBidParams memory _acceptBidParams) private returns (address, uint128) {
        // Validate buy order
        if (_msgSender() == _acceptBidParams.bidder) revert MarketplaceCannotFulfillOwnListingOrBid();
        if (_acceptBidParams.quantity == 0) revert MarketplaceBadQuantity(_acceptBidParams.quantity);
        if (!allowedStablecoins[_acceptBidParams.paymentToken]) {
            revert MarketplaceDisallowedPaymentToken(_acceptBidParams.paymentToken);
        }

        // Validate bid
        ListingOrBid storage _bid = collectionBids[_acceptBidParams.nftAddress][_acceptBidParams.bidder];

        uint64 _bidQty = _bid.quantity;
        if (_bidQty == 0) revert MarketplaceListingOrBidQuantityIsZero();
        if (_bidQty < _acceptBidParams.quantity) revert MarketplaceListingOrBidNotEnoughQuantity(_bidQty);
        uint128 _bidPrice = _bid.pricePerItem;
        if (_bidPrice == 0) revert MarketplaceListingOrBidPriceIsZero();
        if (_bidPrice != _acceptBidParams.pricePerItem) revert MarketplaceListingOrBidPriceDoesNotMatch(_bidPrice);
        if (_bid.expirationTime < block.timestamp) revert MarketplaceListingOrBidAlreadyExpired(_bid.expirationTime);
        address _bidToken = _bid.paymentTokenAddress;

        // Deplete bid quantity
        if (_bidQty == _acceptBidParams.quantity) {
            delete collectionBids[_acceptBidParams.nftAddress][_acceptBidParams.bidder];
        } else {
            unchecked {
                _bid.quantity = _bidQty - _acceptBidParams.quantity;
            }
        }

        return (_bidToken, _bidPrice);
    }

    function _acceptBid(
        AcceptBidParams memory _acceptBidParams,
        address _bidPaymentToken,
        uint128 _pricePerItem
    ) private {
        _validateTokenIsTradeable(_acceptBidParams.nftAddress, _acceptBidParams.tokenId, _acceptBidParams.quantity);

        _enterIntoEscrow(
            _pricePerItem,
            _acceptBidParams.quantity,
            _acceptBidParams.bidder,
            _msgSender(),
            _bidPaymentToken,
            _acceptBidParams.paymentToken
        );

        // Announce accepting bid
        emit BidAccepted(
            _msgSender(),
            _acceptBidParams.bidder,
            _acceptBidParams.nftAddress,
            _acceptBidParams.tokenId,
            _acceptBidParams.quantity,
            _acceptBidParams.pricePerItem,
            _bidPaymentToken,
            _acceptBidParams.bidType
        );
    }

    /**
     * @notice Buy multiple listed items. You must authorize this marketplace with your payment
     *         token to complete the buy, or purchase with native token if it is a wnative
     *         collection.
     *
     *         If the user has a token bid on the exchanged token, the token bid is automatically
     *         cancelled.
     * @param  _buyItemParamsBatch an array of buy-item params
     *
     * Buy-item params:
     * - nftAddress      which token contract holds the offered token
     * - tokenId         the identifier for the offered token
     * - owner           the address currently holding the offered token
     * - quantity        how many of this token identifier are wanted (or 1 for a ERC-721 token)
     * - maxPricePerItem the maximum price (in units of the paymentToken) for each token offered
     * - paymentToken    the payment token used to pay for the wanted token
     * - usingNative     indicates if the user is purchasing this item with native token
     */
    function _buyItems(BuyItemParams[] calldata _buyItemParamsBatch) private {
        for (uint256 i = 0; i < _buyItemParamsBatch.length;) {
            // complete purchase
            _buyItem(_buyItemParamsBatch[i]);

            unchecked { i += 1; }
        }
    }

    function _buyItem(BuyItemParams calldata _buyItemParams) private {
        // Validate buy order
        if (_msgSender() == _buyItemParams.owner) revert MarketplaceCannotFulfillOwnListingOrBid();
        if (_buyItemParams.quantity == 0) revert MarketplaceBadQuantity(_buyItemParams.quantity);
        if (!allowedStablecoins[_buyItemParams.paymentToken]) {
            revert MarketplaceDisallowedPaymentToken(_buyItemParams.paymentToken);
        }

        // Validate listing
        ListingOrBid memory _listedItem = listings[_buyItemParams.nftAddress][_buyItemParams.tokenId][
            _buyItemParams.owner
        ];

        if (_listedItem.quantity == 0) revert MarketplaceListingOrBidQuantityIsZero();
        if (_listedItem.quantity < _buyItemParams.quantity) revert MarketplaceListingOrBidNotEnoughQuantity(_listedItem.quantity);
        uint128 _storedPricePerItem = _listedItem.pricePerItem;
        if (_storedPricePerItem == 0) revert MarketplaceListingOrBidPriceIsZero();
        if (_storedPricePerItem > _buyItemParams.maxPricePerItem) {
            revert MarketplaceListingOrBidPriceDoesNotMatch(_storedPricePerItem);
        }
        if (_listedItem.expirationTime < block.timestamp) {
            revert MarketplaceListingOrBidAlreadyExpired(_listedItem.expirationTime);
        }
        address _collateralToken = _listedItem.paymentTokenAddress;

        // Deplete listing quantity
        if (_listedItem.quantity == _buyItemParams.quantity) {
            delete listings[_buyItemParams.nftAddress][_buyItemParams.tokenId][_buyItemParams.owner];
        } else {
            unchecked {
                listings[_buyItemParams.nftAddress][_buyItemParams.tokenId][_buyItemParams.owner].quantity =
                    _listedItem.quantity - _buyItemParams.quantity;
            }
        }

        _validateTokenIsTradeable(_buyItemParams.nftAddress, _buyItemParams.tokenId, _buyItemParams.quantity);

        _enterIntoEscrow(
            _storedPricePerItem,
            _buyItemParams.quantity,
            _msgSender(),
            _buyItemParams.owner,
            _buyItemParams.paymentToken,
            _collateralToken
        );

        // Announce sale
        emit ItemSold(
            _buyItemParams.owner,
            _msgSender(),
            _buyItemParams.nftAddress,
            _buyItemParams.tokenId,
            _buyItemParams.quantity,
            _storedPricePerItem,
            _buyItemParams.paymentToken
        );
    }

    /**
     * @dev   pays the fees to the marketplace fee recipient, the creator fee recipient if one
     *        exists, and to the seller of the item.
     * @param _storedPricePerItem     the price of the item that is being purchased/accepted
     * @param _quantity               the quantity of the item being purchased/accepted
     * @param _buyer                  the buyer
     * @param _seller                 the seller
     * @param _paymentTokenAddress    the token to use for settlement
     * @param _collateralTokenAddress the token to use for settlement
     */
    function _enterIntoEscrow(
        uint128 _storedPricePerItem,
        uint256 _quantity,
        address _buyer,
        address _seller,
        address _paymentTokenAddress,
        address _collateralTokenAddress
    ) private {
        IERC20 _paymentToken = IERC20(_paymentTokenAddress);
        IERC20 _collateralToken = IERC20(_collateralTokenAddress);

        // Handle purchase price payment
        uint256 _totalPrice = _storedPricePerItem * _quantity;

        // transfer in funds from buyer
        _transferAmount(_buyer, address(this), _totalPrice, _paymentToken);
        // transfer in collateral from seller
        _transferAmount(_seller, address(this), _totalPrice, _collateralToken);
    }

    function _transferAmount(
        address _from,
        address _to,
        uint256 _amount,
        IERC20 _paymentToken
    ) private {
        if (_amount == 0) {
            return;
        }

        _paymentToken.safeTransferFrom(_from, _to, _amount);
    }

    function _initOrder(
        address _nftAddress,
        uint256 _tokenId,
        address _buyer,
        address _seller,
        uint128 _pricePerItem,
        uint64 _quantity,
        address _paymentToken,
        address _collateralToken
    ) private {
        uint16 _numOrders = numOrders;
        orders[_numOrders] = Order(
            _numOrders,
            OrderStatus.Unfulfilled,
            _nftAddress,
            _tokenId,
            _pricePerItem,
            _quantity,
            _buyer,
            _seller,
            _paymentToken,
            _collateralToken
        );

        // mark token id as "ordered"
        orderedTokenIds[_nftAddress][_tokenId] = true;

        // there can not be more than 6000 orders
        unchecked { numOrders = _numOrders + 1; }
    }

    function _revertOrder(OrderParams calldata _orderParams) private {
        Order storage _order = _validateOrderParams(_orderParams);

        _order.status = OrderStatus.Reverted;

        uint256 _totalNeeded = _orderParams.pricePerItem * _orderParams.quantity;
        address _from = address(this);

        emit OrderReverted(_orderParams.orderId);

        // return funds to buyer and seller
        _transferAmount(_from, _orderParams.buyer, _totalNeeded, IERC20(_orderParams.paymentToken));
        _transferAmount(_from, _orderParams.seller, _totalNeeded, IERC20(_orderParams.collateralToken));
    }

    function _fulfillOrder(OrderParams calldata _orderParams) private {
        Order storage _order = _validateOrderParams(_orderParams);

        if (_msgSender() != _orderParams.buyer && _msgSender() != _orderParams.seller) {
            revert MarketplaceUnauthorizedOrderModification();
        }

        Token memory _tokenToFulfill = tokenMappings[_orderParams.nftAddress][_orderParams.tokenId];
        if (_tokenToFulfill.nftAddress == address(0)) {
            revert MarketplaceCannotFulfillBeforeGenesis(_orderParams.nftAddress, _orderParams.tokenId);
        }

        _order.status = OrderStatus.Fulfilled;
        _order.nftAddress = _tokenToFulfill.nftAddress;
        _order.tokenId = _tokenToFulfill.tokenId;

        uint256 _totalNeeded = _orderParams.pricePerItem * _orderParams.quantity;
        uint256 _buyerFees = _totalNeeded * buyerFee / BASIS_POINTS;
        uint256 _sellerFees = _totalNeeded * sellerFee / BASIS_POINTS;
        if (_buyerFees > _totalNeeded) {
            _buyerFees = _totalNeeded;
        }
        if (_sellerFees > _totalNeeded) {
            _sellerFees = _totalNeeded;
        }
        uint256 _netOfFeesBuyer;
        uint256 _netOfFeesSeller;
        unchecked {
            _netOfFeesBuyer = _totalNeeded - _buyerFees;
            _netOfFeesSeller = _totalNeeded - _sellerFees;
        }
        IERC20 _pt = IERC20(_orderParams.paymentToken);
        IERC20 _ct = IERC20(_orderParams.collateralToken);
        address _from = address(this);
        address _feeRecipient = feeRecipient;

        emit OrderFulfilled(_orderParams.orderId);

        // pay fees
        _transferAmount(_from, _feeRecipient, _buyerFees, _pt);
        _transferAmount(_from, _feeRecipient, _sellerFees, _ct);

        // pay seller
        _transferAmount(_from, _orderParams.seller, _netOfFeesBuyer, _pt);

        // return collateral to seller
        _transferAmount(_from, _orderParams.seller, _netOfFeesSeller, _ct);

        // transfer NFT to buyer
        IERC721(_tokenToFulfill.nftAddress).transferFrom(
            _orderParams.seller,
            _orderParams.buyer,
            _tokenToFulfill.tokenId
        );
    }

    function _forfeitOrder(OrderParams calldata _orderParams) private {
        Order storage _order = _validateOrderParams(_orderParams);

        _order.status = OrderStatus.Forfeited;

        uint256 _totalNeeded = _orderParams.pricePerItem * _orderParams.quantity;
        uint256 _buyerFees = _totalNeeded * buyerFee / BASIS_POINTS;
        uint256 _sellerFees = _totalNeeded * sellerFee / BASIS_POINTS;
        if (_buyerFees > _totalNeeded) {
            _buyerFees = _totalNeeded;
        }
        if (_sellerFees > _totalNeeded) {
            _sellerFees = _totalNeeded;
        }
        uint256 _netOfFeesBuyer;
        uint256 _netOfFeesSeller;
        unchecked {
            _netOfFeesBuyer = _totalNeeded - _buyerFees;
            _netOfFeesSeller = _totalNeeded - _sellerFees;
        }
        IERC20 _pt = IERC20(_orderParams.paymentToken);
        IERC20 _ct = IERC20(_orderParams.collateralToken);
        address _from = address(this);
        address _feeRecipient = feeRecipient;

        emit OrderForfeited(_orderParams.orderId);

        // pay fees
        _transferAmount(_from, _feeRecipient, _buyerFees, _pt);
        _transferAmount(_from, _feeRecipient, _sellerFees, _ct);

        // return funds to buyer
        _transferAmount(_from, _orderParams.buyer, _netOfFeesBuyer, _pt);

        // give collateral to buyer
        _transferAmount(_from, _orderParams.buyer, _netOfFeesSeller, _ct);
    }

    function _validateListingOrBidParams(uint128 _pricePerItem, uint64 _expirationTime) private view {
        if (_expirationTime <= block.timestamp) revert MarketplaceExpirationInvalid(_expirationTime);
        if (_pricePerItem < MIN_PRICE) revert MarketplacePriceLessThanMinPrice(_pricePerItem);
        if (_pricePerItem % MIN_PRICE != 0) revert MarketplacePriceInvalidPrecision(_pricePerItem);
    }

    function _validateOrderParams(OrderParams calldata _orderParams) private view returns (Order storage) {
        Order storage _order = orders[_orderParams.orderId];

        if (_order.status != OrderStatus.Unfulfilled) {
            revert MarketplaceModificationForUnfulfilledOrdersOnly(_orderParams.orderId, _order.status);
        }

        if (
            _order.nftAddress != _orderParams.nftAddress ||
            _order.tokenId != _orderParams.tokenId ||
            _order.buyer != _orderParams.buyer ||
            _order.seller != _orderParams.seller ||
            _order.pricePerItem != _orderParams.pricePerItem ||
            _order.quantity != _orderParams.quantity ||
            _order.paymentToken != _orderParams.paymentToken ||
            _order.collateralToken != _orderParams.collateralToken
        ) {
            revert MarketplaceDoesNotMatchOrder(_orderParams.orderId);
        }

        return _order;
    }

    function _validateTokenIsTradeable(address _nftAddress, uint256 _tokenId, uint64 _quantity) private view {
        // make sure token has not been sold already
        if (orderedTokenIds[_nftAddress][_tokenId]) {
            revert MarketplaceTokenAlreadySold(_nftAddress, _tokenId);
        }

        CollectionApprovalStatus status = collectionApprovals[_nftAddress];

        if (status == CollectionApprovalStatus.ERC_721_APPROVED) {
            if (_quantity != 1) {
                revert MarketplaceBadQuantity(_quantity);
            }
            IERC721 _nft = IERC721(_nftAddress);
            address _nftOwner = _nft.ownerOf(_tokenId);
            if (_nftOwner != _msgSender()) {
                revert MarketplaceOwnerDoesNotHoldEnoughQuantity(_nftAddress, _tokenId, 0);
            }
        } else if (status == CollectionApprovalStatus.ERC_1155_APPROVED) {
            if (_quantity == 0) {
                revert MarketplaceBadQuantity(_quantity);
            }
            IERC1155 _nft = IERC1155(_nftAddress);
            uint256 _ownerBalance = _nft.balanceOf(_msgSender(), _tokenId);
            if (_ownerBalance < _quantity) {
                revert MarketplaceOwnerDoesNotHoldEnoughQuantity(_nftAddress, _tokenId, _ownerBalance);
            }
        } else {
            revert MarketplaceCollectionNotApprovedForTrading(_nftAddress);
        }
    }

    function _validatePaymentMethod(uint64 _quantity, uint128 _pricePerItem, address _paymentToken) private view {
        // validate that the collateral is good
        if (!allowedStablecoins[_paymentToken]) revert MarketplaceDisallowedPaymentToken(_paymentToken);

        IERC20 _token = IERC20(_paymentToken);

        uint256 _totalAmountNeeded = _pricePerItem * _quantity;

        uint256 _balanceAllowed = _token.allowance(_msgSender(), address(this));
        uint256 _balanceOwned = _token.balanceOf(_msgSender());
        if (_balanceAllowed < _totalAmountNeeded || _balanceOwned < _totalAmountNeeded) {
            revert MarketplaceNotEnoughPaymentTokens(_balanceAllowed, _balanceOwned, _totalAmountNeeded);
        }
    }
}
