// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum BidType {
    TOKEN,
    COLLECTION,
    MULTI_TOKENS
}

struct CreateOrUpdateListingParams {
    /// which token contract holds the offered token
    address nftAddress;
    /// the identifier for the token to be bought
    uint256 tokenId;
    /// how many of this token identifier to be bought (or 1 for a ERC-721 token)
    uint64 quantity;
    /// the maximum price (in units of the paymentToken) for each token offered
    uint128 pricePerItem;
    /// UNIX timestamp after when this listing expires
    uint64 expirationTime;
    /// the payment token to be used
    address paymentToken;
}

struct CancelListingParams {
    /// which token contract holds the offered token
    address nftAddress;
    /// the identifier for the token to be bought
    uint256 tokenId;
}

struct BuyItemParams {
    /// which token contract holds the offered token
    address nftAddress;
    /// the identifier for the token to be bought
    uint256 tokenId;
    /// current owner of the item(s) to be bought
    address owner;
    /// how many of this token identifier to be bought (or 1 for a ERC-721 token)
    uint64 quantity;
    /// the maximum price (in units of the paymentToken) for each token offered
    uint128 maxPricePerItem;
    /// the payment token to be used
    address paymentToken;
    /// indicates if the user is purchasing this item with native token.
    bool usingNative;
}

struct CreateOrUpdateTokenBidParams {
    /// which token contract holds the offered token
    address nftAddress;
    /// the identifier for the token to be bought
    uint256 tokenId;
    /// how many of this token identifier to be bought (or 1 for a ERC-721 token)
    uint64 quantity;
    /// the maximum price (in units of the paymentToken) for each token offered
    uint128 pricePerItem;
    /// UNIX timestamp after when this listing expires
    uint64 expirationTime;
    /// the payment token to be used
    address paymentToken;
}

struct AcceptBidParams {
    /// The type of bid to accept
    BidType bidType;
    /// Which token contract holds the bidded token
    address nftAddress;
    /// The identifier for the bidded token
    uint256 tokenId;
    /// The user who created the bid initially
    address bidder;
    /// The quantity of items being supplied to the bidder
    uint64 quantity;
    /// The price per item that the bidder is offering
    uint128 pricePerItem;
    /// The payment token to be used
    address paymentToken;
}

struct AcceptBidAdvancedParams {
    AcceptBidParams params;
    /// An optional merkle root hash for multi-token bids
    bytes32 bidHash;
    /// The merkle proof for the accepting token when accepting a multi-token bid
    bytes32[] proof;
}

struct CancelBidParams {
    /// The type of bid to be cancelled
    BidType bidType;
    /// Which token contract holds the bidded token
    address nftAddress;
    /// The identifier for the bidded token, either a uint256 tokenId for token bids or the uint256
    /// representation of a merkle root hash
    uint256 tokenId;
}

struct TransferTokenParams {
    /// Which token contract holds the transferred token
    address nftAddress;
    /// The identifier for the transferred token
    uint256 tokenId;
    /// The quantity of tokens being transferred
    uint256 quantity;
    /// The user who is receiving the tokens
    address recipient;
}

/**
 * @dev Structure for a single hop in a multi-hop swap
 */
struct Swap {
    /// The address of the input token
    address tokenIn;
    /// The address of the output token
    address tokenOut;
    /// Index identifying which router to use
    /// (1: KittenSwap, 2: HyperSwap V2, 3: HyperSwap V3, 4: Laminar, 5: KittenSwap V3)
    uint8 routerIndex;
    /// Only used for HyperSwap V3 (UniswapV3) and Laminar
    uint24 fee;
    /// Represents input amount for exact input swaps, or output amount for exact output swaps
    uint256 amountIn;
    /// Whether the pool is stable (only used for KittenSwap)
    bool stable;
}

struct AltProceedsConfigV0 {
    /// Flag marking that the token is available to be used as an alt proceeds token
    bool active;
    /// Minimum amount of proceeds that can be swapped into this token, in basis points
    uint16 minBps;
}

struct AutostakeConfigV0 {
    /// Flag marking that the token is available to be used as an autostake token
    bool active;
    /// Minimum amount of proceeds that can be autostaked into this token, in basis points
    uint16 minBps;
}

struct UserSettingsV0 {
    /// The selected token to receive alt proceeds in
    address altProceedsTokenAddress;
    /// The amount of proceeds to swap into the alt proceeds token, in basis points
    uint16 altProceedsBps;
    /// The selected token to use for autostaking
    address autostakeTokenAddress;
    /// The amount of proceeds to autostake, in basis points
    uint16 autostakeBps;
    /// Should always auto-unwrap any wrapped native tokens the user receives
    bool autoUnwrapWnative;
}

/**
 * @dev Internal struct used to track user's alt-proceeds conversion
 */
struct UserAltProceeds {
    /// The user receicing the alt proceeds
    address user;
    /// The amount of marketplace fees saved
    uint256 feesSaved;
    /// The amount of the payment tokens to convert
    uint256 amount;
    /// The proceeds token received
    address proceedsToken;
}

/**
 * @dev Spot market information returned by spot info precompile
 */
struct SpotInfo {
    /// Name of spot market
    string name;
    /// The trading pair, in token indexes. Second item is always the base token (i.e. USDC)
    uint64[2] tokens;
}

/**
 * @dev Token information returned by token info precompile
 */
struct HyperCoreToken {
    /// Token name
    string name;
    /// Spot market indexes that trades the token
    uint64[] spots;
    /// Token deployer trading fee share
    uint64 deployerTradingFeeShare;
    /// Token deployer address
    address deployer;
    /// Address of a linked EVM token
    address evmContract;
    /// Decimal size of the spot token
    uint8 szDecimals;
    /// Number of wei decimals of the spot token
    uint8 weiDecimals;
    /// Difference in weiDecimals between EVM token and spot token
    int8 evmExtraWeiDecimals;
}
