# otc-marketplace

This is an OTC Marketplace contract derived from the Drip.Trade main marketplace contract.

This OTC marketplace is built to trade Hypurr NFTs.

Hypurr NFTs are NFTs that will in the future be distributed to ~6000 addresses. These recipients are powerusers of the Hyperliquid dapp. Hypurr NFTs have not yet been released, and will be released at some unknown time in the future. However, even before the NFTs' release, this contract aims to support an OTC market to handle pre-sales of these tokens.

## Behavior

1. A seller may only sell the Hypurr NFT they were airdropped. To complete a sale, sellers must put up collateral equal to the price of the NFT.
1. Buyers may create collection bids for Hypurr NFTs.
1. Sellers may list their to-be-received Hypurr NFT for sale.
1. All sales and collateral are to be denominated in ERC20 stablecoins, namely $USDT0 and $USDe.
1. Once a bid has been accepted, or a listing has been purchased, the funds are locked up in escrow until the Hypurr NFTs are distributed. Buyer or seller will not be able to back out of the trade.
1. Once Hypurr NFTs have been distributed, sellers must fulfill their open orders. Fulfilling an order involves the seller transferring their airdropped Hypurr NFT to its buyer, the seller receiving their collateral back, and the seller receiving the funds paid by the buyer.
1. If a seller does not fulfill their order within a defined period after the Hypurr NFTs have been distributed, the seller forfeits their collateral to the buyer.
1. Marketplace will take a fee from both the buyer and seller in cases of orders that are fulfilled or are forfeited.

## How the marketplace will operate

1. Prior to activating the marketplace, admins will first distribute a soulbound NFT to each would-be-recipient of a Hypurr NFT. Each soulbound NFT will represent a future airdropped Hypurr NFT.
1. The contract address for the soulbound NFT will be approved for trading on the OTC marketplace.
1. On Hypurr NFT distribution, admins will configure add mappings of soulbound NFTs to Hypurr NFTs. This will allow holders of a soulbound NFT to fulfill their orders with its corresponding Hypurr NFT.
1. After all NFT mappings have been added, admins will configure a fulfillment start time and duration. These will determine the amount of time sellers have in order to fulfill their orders prior to forfeiture.
