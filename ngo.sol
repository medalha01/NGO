// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract OrganizationTokenSale is Initializable, ERC1155Upgradeable, ERC1155BurnableUpgradeable, ERC1155HolderUpgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    uint256 public constant MIN_VOTATION_OPTIONS = 2;
    uint256 public constant MAX_VOTATION_OPTIONS = 10;
    uint256 public constant PRICE_DELTA = 1 ether / 1000;
    uint256 public constant BASE_PRICE = 1 ether / 100;
    uint256 public constant VOTING_PERIOD = 7 days;

    enum SaleMode { FixedPrice, FixedQuantity }
    enum VotationState { Proposed, Approved, Rejected, Finalized }

    struct Votation {
        string topic;
        string[] options;
        uint256 quorum;
        uint256 startTime;
        uint256 endTime;
        VotationState state;
        uint256 votesFor;
        uint256 votesAgainst;
        bool exists;
        mapping(uint256 => uint256) votes; 
        mapping(address => uint256) votesSpent;
    }

    struct Organization {
        uint256 tokenId;
        uint256 pricePerToken;
        uint256 tokensAvailable;
        uint256 tokensSold;
        SaleMode saleMode;
        uint256 nextVotationId;
        mapping(uint256 => Votation) votations;
        mapping(address => bool) admins; 
    }

    mapping(address => Organization) private organizations;
    uint256 public nextTokenId;

    event OrganizationTokenCreated(address indexed organization, uint256 tokenId, SaleMode saleMode);
    event TokensBought(address indexed buyer, address indexed organization, uint256 amount, uint256 totalPrice);
    event VotationProposed(address indexed proposer, address indexed organization, uint256 votationId, string topic);
    event VotationApproved(address indexed admin, address indexed organization, uint256 votationId);
    event VotationRejected(address indexed admin, address indexed organization, uint256 votationId);
    event VoteCast(address indexed voter, address indexed organization, uint256 votationId, uint256 optionIndex, uint256 amount);
    event VotationFinalized(address indexed organization, uint256 votationId, bool approved);
    event AdminAdded(address indexed organization, address indexed admin);
    event AdminRemoved(address indexed organization, address indexed admin);

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
    error NotAdmin();
    error VotationNotPendingApproval();
    error VotationAlreadyProcessed();
    error VotationNotActive();
    error QuorumNotMet();
    error VotingPeriodNotEnded();
    error VotationAlreadyFinalized();
    error NotDonor();
    error EmptyTopic();
    error QuorumMustBeGreaterThanZero();
    error VotingPeriodEnded();

    modifier onlyAdmin(address organizationAddress) {
        if (!organizations[organizationAddress].admins[msg.sender]) {
            revert NotAdmin();
        }
        _;
    }

    modifier onlyDonor(address organizationAddress) {
        if (organizations[organizationAddress].tokenId == 0 || balanceOf(msg.sender, organizations[organizationAddress].tokenId) == 0) {
            revert NotDonor();
        }
        _;
    }

    function initialize(string memory uri) public initializer {
        __ERC1155_init(uri);
        __AccessControl_init();
        __ERC1155Burnable_init();
        __ERC1155Holder_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        nextTokenId = 1;
    }

    /**
     * @dev Concede o papel de administrador para um endereço de uma organização específica.
     * Pode ser chamado apenas pelo administrador do contrato.
     */
    function addAdmin(address organization, address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        org.admins[admin] = true;
        emit AdminAdded(organization, admin);
    }

    /**
     * @dev Revoga o papel de administrador de um endereço de uma organização específica.
     * Pode ser chamado apenas pelo administrador do contrato.
     */
    function removeAdmin(address organization, address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        org.admins[admin] = false;
        emit AdminRemoved(organization, admin);
    }

    /**
     * @dev Cria um novo token de organização com oferta inicial e modo de venda.
     * Pode ser chamado apenas pelo administrador do contrato.
     */
    function createOrganizationToken(
        address organization,
        uint256 initialSupply,
        SaleMode saleMode
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (organizations[organization].tokenId != 0) revert OrganizationAlreadyRegistered();
        if (initialSupply == 0) revert InvalidInitialSupply();

        uint256 tokenId = nextTokenId++;
        _mint(address(this), tokenId, initialSupply, "");

        Organization storage org = organizations[organization];
        org.tokenId = tokenId;
        org.saleMode = saleMode;
        org.nextVotationId = 1;
        org.tokensAvailable = initialSupply;

        emit OrganizationTokenCreated(organization, tokenId, saleMode);
    }

    /**
     * @dev Define o preço por token para uma organização.
     * Pode ser chamado apenas pelos administradores da organização.
     */
    function setPricePerToken(uint256 price, address organization) external onlyAdmin(organization) {
        Organization storage org = organizations[organization];
        if (org.saleMode != SaleMode.FixedPrice) revert SaleModeMismatch();
        org.pricePerToken = price;
    }

    /**
     * @dev Ajusta o número de tokens disponíveis para venda no modo de quantidade fixa.
     * Pode ser chamado apenas pelos administradores da organização.
     */
    function adjustTokensAvailable(address organization, int256 amount) external onlyAdmin(organization) {
        Organization storage org = organizations[organization];
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

    /**
     * @dev Permite que os usuários comprem tokens de uma organização.
     */
    function buyTokens(address organization, uint256 amount) external payable nonReentrant {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (org.tokensAvailable < amount) revert NotEnoughTokensAvailable();

        uint256 totalPrice;

        if (org.saleMode == SaleMode.FixedPrice) {
            totalPrice = org.pricePerToken * amount;
        } else {
            uint256 initialPrice = BASE_PRICE + (PRICE_DELTA * org.tokensSold);
            totalPrice = (amount * (2 * initialPrice + PRICE_DELTA * (amount - 1))) / 2;
        }

        if (msg.value != totalPrice) revert IncorrectEtherValueSent();

        org.tokensAvailable -= amount;
        org.tokensSold += amount;

        _safeTransferFrom(address(this), msg.sender, org.tokenId, amount, "");

        (bool success, ) = payable(organization).call{value: msg.value}("");
        if (!success) revert TransferFailed();

        emit TokensBought(msg.sender, organization, amount, totalPrice);
    }

    /**
     * @dev Permite que doadores proponham uma nova votação.
     */
    function proposeVotation(
        address organization,
        string memory topic,
        string[] memory options,
        uint256 quorum
    ) external onlyDonor(organization) {
        Organization storage org = organizations[organization];
        if (options.length < MIN_VOTATION_OPTIONS || options.length > MAX_VOTATION_OPTIONS) revert OptionsOutOfBounds();
        if (bytes(topic).length == 0) revert EmptyTopic();
        if (quorum == 0) revert QuorumMustBeGreaterThanZero();

        uint256 votationId = org.nextVotationId++;
        Votation storage votation = org.votations[votationId];
        votation.topic = topic;
        votation.quorum = quorum;
        votation.state = VotationState.Proposed;
        votation.exists = true;

        for (uint256 i = 0; i < options.length; i++) {
            votation.options.push(options[i]);
        }

        emit VotationProposed(msg.sender, organization, votationId, topic);
    }

    /**
     * @dev Permite que os administradores da organização aprovem uma votação proposta.
     */
    function approveVotation(address organization, uint256 votationId) external onlyAdmin(organization) {
        Votation storage votation = organizations[organization].votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (votation.state != VotationState.Proposed) revert VotationNotPendingApproval();

        votation.state = VotationState.Approved;
        votation.startTime = block.timestamp;
        votation.endTime = block.timestamp + VOTING_PERIOD;

        emit VotationApproved(msg.sender, organization, votationId);
    }

    /**
     * @dev Permite que os administradores da organização rejeitem uma votação proposta.
     */
    function rejectVotation(address organization, uint256 votationId) external onlyAdmin(organization) {
        Votation storage votation = organizations[organization].votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (votation.state != VotationState.Proposed) revert VotationNotPendingApproval();

        votation.state = VotationState.Rejected;

        emit VotationRejected(msg.sender, organization, votationId);
    }

    /**
     * @dev Permite que doadores votem em uma votação ativa.
     */
    function voteOnVotation(
        address organization,
        uint256 votationId,
        uint256 optionIndex,
        uint256 amount
    ) external nonReentrant onlyDonor(organization) {
        Organization storage org = organizations[organization];
        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (votation.state != VotationState.Approved) revert VotationNotActive();
        if (block.timestamp > votation.endTime) revert VotingPeriodEnded();
        if (optionIndex >= votation.options.length) revert InvalidOptionIndex();
        if (amount == 0) revert MustVoteWithAtLeastOneToken();

        uint256 voterBalance = balanceOf(msg.sender, org.tokenId);
        if (voterBalance < amount) revert NotEnoughTokensToVoteWith();

        _burn(msg.sender, org.tokenId, amount);
        votation.votes[optionIndex] += amount;
        votation.votesSpent[msg.sender] += amount;

        // Assumindo que o optionIndex 0 é 'A Favor' e 1 é 'Contra'
        if (optionIndex == 0) {
            votation.votesFor += amount;
        } else if (optionIndex == 1) {
            votation.votesAgainst += amount;
        }

        emit VoteCast(msg.sender, organization, votationId, optionIndex, amount);
    }

    /**
     * @dev Finaliza uma votação após o período de votação ter terminado.
     */
    function finalizeVotation(address organization, uint256 votationId) external {
        Votation storage votation = organizations[organization].votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (votation.state != VotationState.Approved) revert VotationNotActive();
        if (block.timestamp <= votation.endTime) revert VotingPeriodNotEnded();

        uint256 totalVotes = votation.votesFor + votation.votesAgainst;
        bool approved = false;

        if (totalVotes >= votation.quorum && votation.votesFor > votation.votesAgainst) {
            approved = true;
            votation.state = VotationState.Finalized;
        } else {
            votation.state = VotationState.Rejected;
        }

        emit VotationFinalized(organization, votationId, approved);
    }

    /**
     * @dev Recupera os detalhes de uma votação específica.
     */
    function getVotation(address organization, uint256 votationId)
        external
        view
        returns (
            string memory topic,
            string[] memory options,
            uint256 quorum,
            uint256 startTime,
            uint256 endTime,
            VotationState state
        )
    {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();

        topic = votation.topic;
        options = votation.options;
        quorum = votation.quorum;
        startTime = votation.startTime;
        endTime = votation.endTime;
        state = votation.state;
    }

    /**
     * @dev Recupera o número de votos para uma opção específica em uma votação.
     */
    function getVotes(address organization, uint256 votationId, uint256 optionIndex) external view returns (uint256) {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();
        if (optionIndex >= votation.options.length) revert InvalidOptionIndex();

        return votation.votes[optionIndex];
    }

    /**
     * @dev Recupera o número de votos que um eleitor gastou em uma votação específica.
     */
    function getVotesSpent(address organization, uint256 votationId, address voter) external view returns (uint256) {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        Votation storage votation = org.votations[votationId];
        if (!votation.exists) revert VotationDoesNotExist();

        return votation.votesSpent[voter];
    }

    /**
     * @dev Recupera os detalhes do token de uma organização.
     */
    function getOrganization(address organization)
        external
        view
        returns (
            uint256 tokenId,
            uint256 pricePerToken,
            uint256 tokensAvailable,
            uint256 tokensSold,
            SaleMode saleMode,
            uint256 nextVotationId
        )
    {
        Organization storage org = organizations[organization];
        if (org.tokenId == 0) revert OrganizationNotRegistered();

        tokenId = org.tokenId;
        pricePerToken = org.pricePerToken;
        tokensAvailable = org.tokensAvailable;
        tokensSold = org.tokensSold;
        saleMode = org.saleMode;
        nextVotationId = org.nextVotationId;
    }

    /**
     * @dev Sobrescreve a função supportsInterface para incluir múltiplos contratos herdados.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, ERC1155HolderUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
