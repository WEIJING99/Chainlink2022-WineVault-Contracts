pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

contract BottleTypePricePosting is ChainlinkClient, ConfirmedOwner {
  using Chainlink for Chainlink.Request;

  bytes32 private externalJobId;
  uint256 private oraclePayment;

  uint256 public price;
  uint256 public timeUnix;
  uint256 public locationID;
  uint256 public bottleTypeID;

  constructor() ConfirmedOwner(msg.sender){
  setChainlinkToken(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
  setChainlinkOracle(0xedaa6962Cf1368a92e244DdC11aaC49c0A0acC37);
  externalJobId = "a6f858d6d91e468781d6f8a3063ae78b";
  oraclePayment = (0.0 * LINK_DIVISIBILITY); // n * 10**18
  }

  function requestBottlePrice()
    public
  {
    Chainlink.Request memory req = buildChainlinkRequest(externalJobId, address(this), this.fulfillBottlePrice.selector);
    req.add("get", "https://api.npoint.io/5b266f61a171fa487bf1");
    req.add("path1", "bottleTypeID");
    req.add("path2", "timeUnix");
    req.add("path3", "locationID");
    req.add("path4", "price");
    sendOperatorRequest(req, oraclePayment);
  }

  event RequestFulfilledBottlePrice(bytes32 indexed requestId, uint256 indexed bottleTypeID, uint256 timeUnix , uint256 locationID, uint256 price);

  function fulfillBottlePrice(bytes32 requestId, uint256 _bottleTypeID, uint256 _timeUnix, uint _locationID, uint _price)
    public
    recordChainlinkFulfillment(requestId)
  {
    emit RequestFulfilledBottlePrice(requestId, _bottleTypeID, _timeUnix, _locationID, _price);
    bottleTypeID = _bottleTypeID;
    timeUnix = _timeUnix;
    locationID = _locationID;
    price = _price;
  }

}