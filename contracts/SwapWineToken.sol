// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Chainlink Imports
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// This import includes functions from both ./KeeperBase.sol and
// ./interfaces/KeeperCompatibleInterface.sol
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// Dev imports
import "hardhat/console.sol";


contract SwapWineToken is ERC721, ERC721Enumerable, ERC721URIStorage, AutomationCompatibleInterface, Ownable, VRFConsumerBaseV2  {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;
    AggregatorV3Interface public pricefeed;

    // VRF
    VRFCoordinatorV2Interface public COORDINATOR;
    uint256[] public s_randomWords;
    uint256 public s_requestId;
    uint32 public callbackGasLimit = 500000; // set higher as fulfillRandomWords is doing a LOT of heavy lifting.
    uint64 public s_subscriptionId;
    bytes32 keyhash =  0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15; // keyhash, https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/#goerli-testnet
    
    /**
    * Use an interval in seconds and a timestamp to slow execution of Upkeep
    */
    uint public /* immutable */ interval; 
    uint public lastTimeStamp;
    int256 public currentPrice;

    enum MarketTrend{UP, DOWN} // Create Enum
    MarketTrend public currentMarketTrend = MarketTrend.UP; 
    
    // IPFS URIs for the dynamic nft graphics/metadata.
    // NOTE: These connect to my IPFS Companion node.
    // You should upload the contents of the /ipfs folder to your own node for development.
    string[] upUrisIpfs = [
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/central.json",
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/left.json",
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/right.json"
    ];
    string[] downUrisIpfs = [
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/sleepy.json",
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/top-left.json",
        "https://ipfs.filebase.io/ipfs/QmXNDtk9FENognzvFLm2ZNtKZWRJ32oGMV4GW6VsFEBW1S/top-right.json"
    ];

    event TokensUpdated(string marketTrend);

    // For testing with the mock, pass in 10(seconds) for `updateInterval` and the address of your 
    // deployed  MockPriceFeed.sol contract.
    // Setup VRF.
    constructor(uint updateInterval, address _pricefeed, address _vrfCoordinator) ERC721("SwapWineToken", "SWT") VRFConsumerBaseV2(_vrfCoordinator) {
        // Set the keeper update interval
        interval = updateInterval; 
        lastTimeStamp = block.timestamp;  //  seconds since unix epoch

        pricefeed = AggregatorV3Interface(_pricefeed); // To pass in the mock
        // set the price for the chosen currency pair.
        currentPrice = getLatestPrice();
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);  
    }

    function safeMint(address to) public  {
        // Current counter value will be the minted token's token ID.
        uint256 tokenId = _tokenIdCounter.current();

        // Increment it so next time it's correct when we call .current()
        _tokenIdCounter.increment();

        // Mint the token
        _safeMint(to, tokenId);

        // Default to a NFT with central eyes on token minting.
        string memory defaultUri = upUrisIpfs[0];
        _setTokenURI(tokenId, defaultUri);

        console.log("DONE!!! minted token ", tokenId, " and assigned token url: ", defaultUri);
    }

    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory /*performData */) {
         upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
    }

    // Modified to handle VRF.
    function performUpkeep(bytes calldata /* performData */ ) external override {
        //We highly recommend revalidating the upkeep in the performUpkeep function
        if ((block.timestamp - lastTimeStamp) > interval ) {
            lastTimeStamp = block.timestamp;         
            int latestPrice =  getLatestPrice(); 
        
            if (latestPrice == currentPrice) {
                console.log("NO CHANGE -> returning!");
                return;
            }

            if (latestPrice < currentPrice) {
                // down
                currentMarketTrend = MarketTrend.DOWN;
            } else {
                // up
                currentMarketTrend = MarketTrend.UP;
            }

            // Initiate the VRF calls to get a random number (word)
            // that will then be used to to choose one of the URIs 
            // that gets applied to all minted tokens.
            requestRandomnessForNFTUris();
            // update currentPrice
            currentPrice = latestPrice;
        } else {
            console.log(
                " INTERVAL NOT UP!"
            );
            return;
        }
    }

    function getLatestPrice() public view returns (int256) {
         (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = pricefeed.latestRoundData();

        return price; //  example price returned 3034715771688
    }

    function requestRandomnessForNFTUris() internal {
        require(s_subscriptionId != 0, "Subscription ID not set"); 

        // Will revert if subscription is not set and funded.
        s_requestId = COORDINATOR.requestRandomWords(
            keyhash,
            s_subscriptionId, // See https://vrf.chain.link/
            3, //minimum confirmations before response
            callbackGasLimit,
            1 // `numWords` : number of random values we want. Max number for goerli is 500
        );

        console.log("Request ID: ", s_requestId);

        // requestId looks like uint256: 80023009725525451140349768621743705773526822376835636211719588211198618496446
    }

 // This is the callback that the VRF coordinator sends the 
 // random values to.
  function fulfillRandomWords(
    uint256, /* requestId */
    uint256[] memory randomWords
  ) internal override {
    s_randomWords = randomWords;
    // randomWords looks like this uint256: 68187645017388103597074813724954069904348581739269924188458647203960383435815

    console.log("...Fulfilling random Words");
    
    string[] memory urisForTrend = currentMarketTrend == MarketTrend.UP ? upUrisIpfs : downUrisIpfs;
    uint256 idx = randomWords[0] % urisForTrend.length; // use modulo to choose a random index.


    for (uint i = 0; i < _tokenIdCounter.current() ; i++) {
        _setTokenURI(i, urisForTrend[idx]);
    } 

    string memory trend = currentMarketTrend == MarketTrend.UP ? "up" : "down";
    
    emit TokensUpdated(trend);
  }


  function setPriceFeed(address newFeed) public onlyOwner {
      pricefeed = AggregatorV3Interface(newFeed);
  }
  function setInterval(uint256 newInterval) public onlyOwner {
      interval = newInterval;
  }

  // For VRF Subscription Manager
  function setSubscriptionId(uint64 _id) public onlyOwner {
      s_subscriptionId = _id;
  }


  function setCallbackGasLimit(uint32 maxGas) public onlyOwner {
      callbackGasLimit = maxGas;
  }

  function setVrfCoodinator(address _address) public onlyOwner {
    COORDINATOR = VRFCoordinatorV2Interface(_address);
  }
    


    // Helpers
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        // No longer used as not being called when using VRF, as we're now using enums.
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function updateAllTokenUris(string memory trend) internal {
      // The logic from this has been moved up to fulfill random words.
    }



    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}