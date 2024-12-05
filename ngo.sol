// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract OrganizationTokenSale is ERC1155, Ownable, ReentrancyGuard, ERC1155Holder {
    uint256 public nextTokenId = 1;

    // Constants for limits
    uint256 public constant MIN_VOTATION_OPTIONS = 2;
    uint256 public constant MAX_VOTATION_OPTIONS = 10;
    uint256 public constant PRICE_DELTA = 1 ether / 1000; 
    uint256 public constant BASE_PRICE = 1 ether / 100; 

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

    event OrganizationTokenCreated(address indexed organizationAddress, uint256 tokenId, SaleMode saleMode);
    event TokensBought(address indexed buyer, address indexed organizationAddress, uint256 amount, uint256 totalPrice);
    event VotationCreated(address indexed organizationAddress, uint256 votationId, string topic);
    event VoteCast(address indexed voter, address indexed organizationAddress, uint256 votationId, uint256 optionIndex, uint256 amount);

    error OrganizationNotRegistered();
    error OrganizationAlreadyRegistered();
    error SaleModeMismatch();
    error NotEnoughTokensAvailable();
    error IncorrectEtherValueSent();
    error InvalidOptionIndex();
    error VotationDoesNotExist();
    error MustVoteWithAtLeastOneToken();
    error OptionsOutOfBounds();
    error NotEnoughTokensToVoteWith();
    error TransferFailed();
    error AmountMustBeGreaterThanZero();
    error InvalidInitialSupply();

    constructor() ERC1155("") Ownable(msg.sender) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function createOrganizationToken(
        address organizationAddress,
        uint256 initialSupply,
        SaleMode saleMode
    ) external onlyOwner {
        if (organizations[organizationAddress].tokenId != 0) revert OrganizationAlreadyRegistered();
        if (initialSupply == 0) revert InvalidInitialSupply();

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        _mint(address(this), tokenId, initialSupply, "");

        Organization storage org = organizations[organizationAddress];
        org.tokenId = tokenId;
        org.saleMode = saleMode;
        org.nextVotationId = 1;
        org.tokensSold = 0;
        org.tokensAvailable = initialSupply;

        emit OrganizationTokenCreated(organizationAddress, tokenId, saleMode);
    }

    function setPricePerToken(uint256 price) external {
        Organization storage org = organizations[msg.sender];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        if (org.saleMode != SaleMode.FixedPrice) revert SaleModeMismatch();
        org.pricePerToken = price;
    }

    function adjustTokensAvailable(int256 amount) external {
        Organization storage org = organizations[msg.sender];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        if (org.saleMode != SaleMode.FixedQuantity) revert SaleModeMismatch();
        if (amount > 0) {
            uint256 amt = uint256(amount);
            _mint(address(this), org.tokenId, amt, "");
            org.tokensAvailable += amt;
        } else if (amount < 0) {
            uint256 amt = uint256(-amount);
            if (org.tokensAvailable < amt) revert NotEnoughTokensAvailable();
            _burn(address(this), org.tokenId, amt);
            org.tokensAvailable -= amt;
        }
    }

    function buyTokens(address organizationAddress, uint256 amount) external payable nonReentrant {
        Organization storage org = organizations[organizationAddress];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (org.tokensAvailable < amount) revert NotEnoughTokensAvailable();

        uint256 totalPrice;

        if (org.saleMode == SaleMode.FixedPrice) {
            totalPrice = org.pricePerToken * amount;
        } else if (org.saleMode == SaleMode.FixedQuantity) {
            uint256 initialPrice = BASE_PRICE + (PRICE_DELTA * org.tokensSold);
            uint256 numerator = amount * (2 * initialPrice + PRICE_DELTA * (amount - 1));
            totalPrice = numerator / 2;
        }

        if (msg.value != totalPrice) revert IncorrectEtherValueSent();

        org.tokensAvailable -= amount;
        org.tokensSold += amount;

        _safeTransferFrom(address(this), msg.sender, org.tokenId, amount, "");

        (bool success, ) = payable(organizationAddress).call{value: msg.value}("");
        if (!success) revert TransferFailed();

        emit TokensBought(msg.sender, organizationAddress, amount, totalPrice);
    }

    function createVotation(string memory topic, string[] memory options) external {
        Organization storage org = organizations[msg.sender];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        if (options.length < MIN_VOTATION_OPTIONS || options.length > MAX_VOTATION_OPTIONS) revert OptionsOutOfBounds();
        require(bytes(topic).length > 0, "Topic must not be empty");

        uint256 votationId = org.nextVotationId;
        org.nextVotationId++;

        Votation storage votation = org.votations[votationId];
        votation.topic = topic;
        votation.exists = true;

        for (uint256 i = 0; i < options.length; i++) {
            votation.options.push(options[i]);
        }

        emit VotationCreated(msg.sender, votationId, topic);
    }

    function voteOnVotation(
        address organizationAddress,
        uint256 votationId,
        uint256 optionIndex,
        uint256 amount
    ) external {
        Organization storage org = organizations[organizationAddress];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (optionIndex >= votation.options.length) revert InvalidOptionIndex();
        if (amount == 0) revert MustVoteWithAtLeastOneToken();

        uint256 voterBalance = balanceOf(msg.sender, org.tokenId);
        if (voterBalance < amount) revert NotEnoughTokensToVoteWith();

        _burn(msg.sender, org.tokenId, amount);
        votation.votes[optionIndex] += amount;
        votation.votesSpent[msg.sender] += amount;

        emit VoteCast(msg.sender, organizationAddress, votationId, optionIndex, amount);
    }

    function getVotation(address organizationAddress, uint256 votationId)
        external
        view
        returns (string memory topic, string[] memory options)
    {
        Organization storage org = organizations[organizationAddress];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();

        topic = votation.topic;
        options = votation.options;
    }

    function getVotes(
        address organizationAddress,
        uint256 votationId,
        uint256 optionIndex
    ) external view returns (uint256) {
        Organization storage org = organizations[organizationAddress];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (optionIndex >= votation.options.length) revert InvalidOptionIndex();

        return votation.votes[optionIndex];
    }

    function getVotesSpent(
        address organizationAddress,
        uint256 votationId,
        address voter
    ) external view returns (uint256) {
        Organization storage org = organizations[organizationAddress];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();

        return votation.votesSpent[voter];
    }
}
