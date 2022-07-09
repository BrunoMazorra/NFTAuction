pragma solidity ^0.8.0;

import "./ERC20.sol";
import "./NFTCollection.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../artifacts/v2-periphery/contracts/UniswapV2Router02.sol";
import '../artifacts/v2-periphery/contracts/libraries/UniswapV2Library.sol';
import "hardhat/console.sol"; 

contract Marketplace is IERC721Receiver {
    // Name of the marketplace
    string public name;

    // Index of auctions
    uint256 public index = 0;
    address factory;
    address inch;
    UniswapV2Router02 router;
    mapping(uint256=>mapping(address=>mapping(address=>uint256))) public ClaimRights;
    
    // constructor of the contract
    constructor(address _router,address _inch,string memory _name) public {
        router = UniswapV2Router02(_router);
        inch = _inch;
        name = _name;
    }

    // Structure to define auction properties
     struct Bid{
        address tokenAddress;
        uint256 amount;
    }
    struct Auction {
        uint256 index; // Auction Index
        address addressNFTCollection; // Address of the ERC721 NFT Collection contract
        address addressPaymentToken; // Address of the ERC20 Payment Token contract
        uint256 nftId; // NFT Id
        address creator; // Creator of the Auction
        address payable currentBidOwner; // Address of the highest bider
        uint256 currentBidPrice; // Current highest bid for the auction
        uint256 endAuction; // Timestamp for the end day&time of the auction
        uint256 byzantineEndingTime;
        uint256 bidCount; // Number of bid placed on the auction
        Bid[] bids;       // List of bids
    }
   

    // Array will all auctions
    Auction[] private allAuctions;

    // Public event to notify that a new auction has been created
    event NewAuction(
        uint256 index,
        address addressNFTCollection,
        address addressPaymentToken,
        uint256 nftId,
        address mintedBy,
        address currentBidOwner,
        uint256 currentBidPrice,
        uint256 endAuction,
        uint256 bidCount,
        bool executed
    );

    // Public event to notify that a new bid has been placed
    event NewBidOnAuction(uint256 auctionIndex, uint256 newBid);

    // Public event to notif that winner of an
    // auction claim for his reward
    event NFTClaimed(uint256 auctionIndex, uint256 nftId, address claimedBy);

    // Public event to notify that the creator of
    // an auction claimed for his money
    event TokensClaimed(uint256 auctionIndex, uint256 nftId, address claimedBy);

    // Public event to notify that an NFT has been refunded to the
    // creator of an auction
    event NFTRefunded(uint256 auctionIndex, uint256 nftId, address claimedBy);



    /**
     * Check if a specific address is
     * a contract address
     * @param _addr: address to verify
     */
    function isContract(address _addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /**
     * Create a new auction of a specific NFT
     * @param _addressNFTCollection address of the ERC721 NFT collection contract
     * @param _addressPaymentToken address of the ERC20 payment token contract
     * @param _nftId Id of the NFT for sale
     * @param _initialBid Inital bid decided by the creator of the auction
     * @param _endAuction Timestamp with the end date and time of the auction
     */
    function createAuction(
        address _addressNFTCollection,
        address _addressPaymentToken,
        uint256 _nftId,
        uint256 _initialBid,
        uint256 _endAuction,
        uint256 _byzantineEndingTime
    ) external returns (uint256) {
        //Check is addresses are valid
        require(
            isContract(_addressNFTCollection),
            "Invalid NFT Collection contract address"
        );
        require(
            isContract(_addressPaymentToken),
            "Invalid Payment Token contract address"
        );

        // Check if the endAuction time is valid
        require(_endAuction > block.timestamp, "Invalid end date for auction");

        // Check if the initial bid price is > 0
        require(_initialBid > 0, "Invalid initial bid price");

        // Get NFT collection contract
        NFTCollection nftCollection = NFTCollection(_addressNFTCollection);

        // Make sure the sender that wants to create a new auction
        // for a specific NFT is the owner of this NFT
        require(
            nftCollection.ownerOf(_nftId) == msg.sender,
            "Caller is not the owner of the NFT"
        );

        // Make sure the owner of the NFT approved that the MarketPlace contract
        // is allowed to change ownership of the NFT
        require(
            nftCollection.getApproved(_nftId) == address(this),
            "Require NFT ownership transfer approval"
        );

        // Lock NFT in Marketplace contract
        require(nftCollection.transferNFTFrom(msg.sender, address(this), _nftId));

        //Casting from address to address payable
        address payable currentBidOwner = payable(address(0));
        // Create new Auction object
        Auction memory newAuction = Auction({
            index: index,
            addressNFTCollection: _addressNFTCollection,
            addressPaymentToken: _addressPaymentToken,
            nftId: _nftId,
            creator: msg.sender,
            currentBidOwner: currentBidOwner,
            currentBidPrice: _initialBid,
            endAuction: _endAuction,
            byzantineEndingTime: _byzantineEndingTime,
            bidCount: 0,
            executed:false
        });
        //update list
        allAuctions.push(newAuction);
        // increment auction sequence
        index++;
        return index;
    }

    /**
     * Check if an auction is open
     * @param _auctionIndex Index of the auction
     */
    function isOpen(uint256 _auctionIndex) public view returns (bool) {
        Auction storage auction = allAuctions[_auctionIndex];
        if (block.timestamp >= auction.endAuction) return false;
        return true;
    }

     /**
     * Return the current highest bid price
     * for a specific auction
     * @param _auctionIndex Index of the auction
     */
    function getCurrentBid(uint256 _auctionIndex)
        public
        view
        returns (uint256)
    {
        address numeraire = currentAuction.addressPaymentToken;
        address path;
        address maxBid;
        uint256 bid;

        require(_auctionIndex < allAuctions.length, "Invalid auction index");
        Auction currentAuction = allAuctions[_auctionIndex];
        
        for (i=0;i<currentAuction.bids.length;i++){
            path = UniswapV2Library.pairFor(factory, currentAuction.bids[i].tokenAddress, numeraire);
            bid = router.getAmountsOut(currentAuction.bids[i].amount,path)[0];
            if(maxBid < bid){
                maxBid = bid;
            }
        }
        return maxBid;
    }
     /**
     * Place new bid on a specific auction
     * @param _auctionIndex Index of auction
     * @param _newBid New bid price
     */
    function bid(Bid bid, uint256 _auctionIndex) external {
        require(_auctionIndex < allAuctions.length, "Invalid auction index");
        require(!isOpen(_auctionIndex), "Auction is still open");
        require(
            ERC20(allAuctions[_auctionIndex].paymentToken).transferFrom(msg.sender, address(this), bid.amount),
            "Tranfer of token failed"
        );
        ClaimRights[_auctionIndex][msg.sender][tokenAddress] += bid.amount;

    }

    function claimTokens(uint256 _auctionIndex){
        require(allAuctions[_auctionIndex].executed || block.timestamp >= byzantineEndingTime);
        ERC20(allAuctions[_auctionIndex].paymentToken).transfer(
            msg.sender,
            ClaimRights[_auctionIndex][msg.sender][tokenAddress]
            );
        ClaimRights[_auctionIndex][msg.sender][tokenAddress] = 0;
    }

    function executeEndAuction(uint256 _auctionIndex,address winner,address token){
        require(allAuctions[_auctionIndex].creator == msg.sender);
        require(!isOpen(_auctionIndex), "Auction is still open");
        require(!allAuctions[_auctionIndex].executed);

        nftCollection.transferFrom(
            address(this),
            winner,
            auction.nftId
        );
        ERC20 paymentToken = ERC20(auction.addressPaymentToken);
        // Transfer locked tokens from the market place contract
        // to the wallet of the creator of the auction
        paymentToken.transfer(auction.creator, ClaimRights[_auctionIndex][winner][token]);
        ClaimRights[_auctionIndex][winner][token] = 0;
        allAuctions[_auctionIndex].executed = true;

    }
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

}
