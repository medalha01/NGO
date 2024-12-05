// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OrganizationTokenSale is ERC1155, Ownable {
    uint256 public nextTokenId = 1;

    enum SaleMode { FixedPrice, FixedQuantity }

    struct Votation {
        string topic;
        string[] options;
        mapping(uint256 => uint256) votes;
        mapping(address => uint256) votesSpent;
        bool exists;
    }

    struct Organization {
        uint256 tokenId;
        uint256 pricePerToken;
        uint256 tokensAvailable;
        uint256 tokensSold;
        SaleMode saleMode;
        uint256 nextVotationId;
        mapping(uint256 => Votation) votations;
    }

    mapping(address => Organization) public organizations;

    constructor() ERC1155("") Ownable(msg.sender) {}

    function createOrganizationToken(
        address organizationAddress,
        uint256 initialSupply,
        SaleMode saleMode
    ) external onlyOwner {
        uint256 tokenId = nextTokenId;
        nextTokenId++;
        
        if (saleMode == SaleMode.FixedPrice) {
            _mint(organizationAddress, tokenId, initialSupply, "");
        } else if (saleMode == SaleMode.FixedQuantity) {
            _mint(address(this), tokenId, initialSupply, "");
        }
        
        Organization storage org = organizations[organizationAddress];
        org.tokenId = tokenId;
        org.saleMode = saleMode;
        org.nextVotationId = 1;
        org.tokensSold = 0;
        
        if (saleMode == SaleMode.FixedQuantity) {
            org.tokensAvailable = initialSupply;
        }
    }

    function setPricePerToken(uint256 price) external {
        Organization storage org = organizations[msg.sender];
        require(org.tokenId != 0, "Organization not registered");
        require(org.saleMode == SaleMode.FixedPrice, "Sale mode is not Fixed Price");
        org.pricePerToken = price;
    }

    function adjustTokensAvailable(int256 amount) external {
        Organization storage org = organizations[msg.sender];
        require(org.tokenId != 0, "Organization not registered");
        require(org.saleMode == SaleMode.FixedQuantity, "Sale mode is not Fixed Quantity");
        if (amount >= 0) {
            uint256 amt = uint256(amount);
            _mint(address(this), org.tokenId, amt, "");
            org.tokensAvailable += amt;
        } else {
            uint256 amt = uint256(-amount);
            require(org.tokensAvailable >= amt, "Not enough tokens available");
            _burn(address(this), org.tokenId, amt);
            org.tokensAvailable -= amt;
        }
    }

    function buyTokens(address organizationAddress, uint256 amount) external payable {
        Organization storage org = organizations[organizationAddress];
        require(org.tokenId != 0, "Organization not registered");

        if (org.saleMode == SaleMode.FixedPrice) {
            uint256 totalPrice = org.pricePerToken * amount;
            require(msg.value == totalPrice, "Incorrect Ether value sent");
            safeTransferFrom(organizationAddress, msg.sender, org.tokenId, amount, "");
            payable(organizationAddress).transfer(msg.value);
        } else if (org.saleMode == SaleMode.FixedQuantity) {
            require(org.tokensAvailable >= amount, "Not enough tokens available");
            uint256 delta = 1 ether / 1000;
            uint256 initialPrice = (1 ether / 100) + (delta * org.tokensSold);
            uint256 numerator = amount * (2 * initialPrice + delta * (amount - 1));
            uint256 totalPrice = numerator / 2;
            require(msg.value == totalPrice, "Incorrect Ether value sent");
            _safeTransferFrom(address(this), msg.sender, org.tokenId, amount, "");
            org.tokensAvailable -= amount;
            org.tokensSold += amount;
            payable(organizationAddress).transfer(msg.value);
        }
    }

    function createVotation(string memory topic, string[] memory options) external {
        Organization storage org = organizations[msg.sender];
        require(org.tokenId != 0, "Organization not registered");
        require(options.length > 1 && options.length <= 10, "Options must be between 2 and 10");

        uint256 votationId = org.nextVotationId;
        org.nextVotationId++;

        Votation storage votation = org.votations[votationId];
        votation.topic = topic;
        votation.exists = true;

        for (uint256 i = 0; i < options.length; i++) {
            votation.options.push(options[i]);
        }
    }

    function voteOnVotation(
        address organizationAddress,
        uint256 votationId,
        uint256 optionIndex,
        uint256 amount
    ) external {
        Organization storage org = organizations[organizationAddress];
        require(org.tokenId != 0, "Organization not registered");

        Votation storage votation = org.votations[votationId];
        require(votation.exists, "Votation does not exist");
        require(optionIndex < votation.options.length, "Invalid option index");

        uint256 voterBalance = balanceOf(msg.sender, org.tokenId);
        require(voterBalance >= amount, "Not enough tokens to vote with");
        require(amount > 0, "Must vote with at least one token");

        _burn(msg.sender, org.tokenId, amount);
        votation.votes[optionIndex] += amount;
        votation.votesSpent[msg.sender] += amount;
    }

    function getVotation(address organizationAddress, uint256 votationId)
        external
        view
        returns (string memory topic, string[] memory options)
    {
        Organization storage org = organizations[organizationAddress];
        require(org.tokenId != 0, "Organization not registered");

        Votation storage votation = org.votations[votationId];
        require(votation.exists, "Votation does not exist");

        topic = votation.topic;
        options = votation.options;
    }

    function getVotes(
        address organizationAddress,
        uint256 votationId,
        uint256 optionIndex
    ) external view returns (uint256) {
        Organization storage org = organizations[organizationAddress];
        require(org.tokenId != 0, "Organization not registered");

        Votation storage votation = org.votations[votationId];
        require(votation.exists, "Votation does not exist");
        require(optionIndex < votation.options.length, "Invalid option index");

        return votation.votes[optionIndex];
    }

    function getVotesSpent(
        address organizationAddress,
        uint256 votationId,
        address voter
    ) external view returns (uint256) {
        Organization storage org = organizations[organizationAddress];
        require(org.tokenId != 0, "Organization not registered");

        Votation storage votation = org.votations[votationId];
        require(votation.exists, "Votation does not exist");

        return votation.votesSpent[voter];
    }
}
