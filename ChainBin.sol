// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  ChainBin.sol — events-first, minimal-state collaboration platform (final corrected)
  - Events store full title/content (large data).
  - State stores contentHash (bytes32) only + minimal metadata & permissions.
  - Internal helper _createPaste uses memory strings to accept literals.
  - Fixed: getIdsRange returns new uint256[](0) for empty ranges.
  - Attachment support included.
*/

contract ChainBin {
    // --- Config ---
    uint256 public constant MAX_BYTES = 65535; // ~64KB per paste
    uint256 public nextId = 1;
    uint256 public totalDonations;
    address payable public immutable beneficiary;

    // --- Meta/state ---
    struct Meta {
        address owner;
        address author;
        uint64 timestamp;
        uint256 donation;
    }
    mapping(uint256 => Meta) public meta; // pasteId => meta

    // Small on-chain fingerprint of content only
    mapping(uint256 => bytes32) public contentHash;

    // attachments: pasteId -> human-readable CID
    mapping(uint256 => string) public attachmentCid;

    // slugHash -> pasteId (0 = none)
    mapping(bytes32 => uint256) public slugToId;

    // editors: pasteId -> address -> allowed
    mapping(uint256 => mapping(address => bool)) public editors;

    // upvotes: pasteId -> voter -> bool
    mapping(uint256 => mapping(address => bool)) public hasUpvoted;
    mapping(uint256 => uint256) public upvoteCount;

    // reentrancy guard
    uint8 private _locked;
    modifier nonReentrant() {
        require(_locked == 0, "Reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    // --- Events (full content in events) ---
    event PasteCreated(
        uint256 indexed id,
        address indexed owner,
        address indexed author,
        uint64 timestamp,
        uint256 donation,
        string title,
        string content
    );

    event PasteReplied(
        uint256 indexed id,
        uint256 indexed parentId,
        address indexed author,
        uint64 timestamp,
        uint256 donation,
        string content
    );

    event PasteEdited(uint256 indexed id, address indexed editor, uint64 timestamp, string newContent);
    event SlugClaimed(bytes32 indexed slugHash, string slug, uint256 indexed id, address claimer);
    event EditorAdded(uint256 indexed id, address indexed editor, address indexed by);
    event EditorRemoved(uint256 indexed id, address indexed editor, address indexed by);
    event Upvoted(uint256 indexed id, address indexed voter, uint256 newTotal);
    event BatchCreated(uint256 indexed firstId, uint256 count, address indexed creator, uint64 timestamp);
    event TipForwarded(uint256 indexed id, address indexed from, address indexed to, uint256 amount);
    event AttachmentAdded(uint256 indexed id, address indexed by, string cid);

    // --- Constructor ---
    constructor(address payable _beneficiary) {
        require(_beneficiary != address(0), "zero beneficiary");
        beneficiary = _beneficiary;
    }

    // -------------------------
    // Internal helper (memory params to accept literals)
    // -------------------------
    function _createPaste(
        string memory title,
        string memory content,
        address ownerAddr,
        address authorAddr,
        uint256 donation
    ) internal returns (uint256 id) {
        id = nextId++;
        meta[id] = Meta({ owner: ownerAddr, author: authorAddr, timestamp: uint64(block.timestamp), donation: donation });
        contentHash[id] = keccak256(bytes(content));
        if (donation > 0) totalDonations += donation;
        emit PasteCreated(id, ownerAddr, authorAddr, uint64(block.timestamp), donation, title, content);
    }

    // -------------------------
    // Creation / Writing
    // -------------------------
    function write(string calldata title, string calldata content) external payable returns (uint256 id) {
        bytes calldata data = bytes(content);
        require(data.length > 0, "empty content");
        require(data.length <= MAX_BYTES, "content too big");
        id = _createPaste(title, content, msg.sender, msg.sender, msg.value);
    }

    function reply(uint256 parentId, string calldata content) external payable returns (uint256 id) {
        require(meta[parentId].owner != address(0), "parent not found");
        bytes calldata data = bytes(content);
        require(data.length > 0, "empty content");
        require(data.length <= MAX_BYTES, "content too big");
        id = _createPaste("", content, meta[parentId].owner, msg.sender, msg.value);
        emit PasteReplied(id, parentId, msg.sender, uint64(block.timestamp), msg.value, content);
    }

    // -------------------------
    // Batch operations (uses helper to avoid stack-too-deep)
    // -------------------------
    function writeMany(string[] calldata titles, string[] calldata contents) external payable returns (uint256 firstId, uint256 count) {
        require(titles.length == contents.length, "mismatched arrays");
        require(titles.length > 0, "no items");

        count = titles.length;
        firstId = nextId;
        uint256 per = 0;
        if (msg.value > 0) per = msg.value / count;

        for (uint256 i = 0; i < count; ++i) {
            bytes calldata data = bytes(contents[i]);
            require(data.length > 0, "empty item");
            require(data.length <= MAX_BYTES, "item too big");
            _createPaste(titles[i], contents[i], msg.sender, msg.sender, per);
        }

        emit BatchCreated(firstId, count, msg.sender, uint64(block.timestamp));
    }

    // -------------------------
    // Slugs (vanity URLs)
    // -------------------------
    function claimSlug(uint256 pasteId, string calldata slug) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(msg.sender == meta[pasteId].owner, "only owner");
        bytes32 h = keccak256(bytes(slug));
        require(slugToId[h] == 0, "slug taken");
        slugToId[h] = pasteId;
        emit SlugClaimed(h, slug, pasteId, msg.sender);
    }

    function getIdBySlug(string calldata slug) external view returns (uint256) {
        return slugToId[keccak256(bytes(slug))];
    }

    // -------------------------
    // Editors / Permissions
    // -------------------------
    function addEditor(uint256 pasteId, address editor) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(msg.sender == meta[pasteId].owner, "only owner");
        editors[pasteId][editor] = true;
        emit EditorAdded(pasteId, editor, msg.sender);
    }

    function removeEditor(uint256 pasteId, address editor) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(msg.sender == meta[pasteId].owner, "only owner");
        editors[pasteId][editor] = false;
        emit EditorRemoved(pasteId, editor, msg.sender);
    }

    function edit(uint256 pasteId, string calldata newContent) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(msg.sender == meta[pasteId].owner || editors[pasteId][msg.sender], "not authorized");
        bytes calldata data = bytes(newContent);
        require(data.length > 0, "empty content");
        require(data.length <= MAX_BYTES, "content too big");
        contentHash[pasteId] = keccak256(data);
        emit PasteEdited(pasteId, msg.sender, uint64(block.timestamp), newContent);
    }

    // -------------------------
    // Attachments
    // -------------------------
    function addAttachment(uint256 pasteId, string calldata cid) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(bytes(cid).length > 0, "empty cid");
        bool allowed = (msg.sender == meta[pasteId].owner) || (msg.sender == meta[pasteId].author) || editors[pasteId][msg.sender];
        require(allowed, "not authorized to attach");
        attachmentCid[pasteId] = cid;
        emit AttachmentAdded(pasteId, msg.sender, cid);
    }

    // -------------------------
    // Social: Upvotes
    // -------------------------
    function upvote(uint256 pasteId) external {
        require(meta[pasteId].owner != address(0), "paste not found");
        require(!hasUpvoted[pasteId][msg.sender], "already voted");
        hasUpvoted[pasteId][msg.sender] = true;
        upvoteCount[pasteId] += 1;
        emit Upvoted(pasteId, msg.sender, upvoteCount[pasteId]);
    }

    // -------------------------
    // Tips & Funds
    // -------------------------
    function tip(uint256 pasteId) external payable nonReentrant {
        require(msg.value > 0, "no tip");
        address payable to = payable(meta[pasteId].owner);
        require(to != address(0), "recipient not found");
        (bool ok, ) = to.call{value: msg.value}("");
        require(ok, "transfer failed");
        emit TipForwarded(pasteId, msg.sender, to, msg.value);
    }

    function withdraw() external nonReentrant {
        require(msg.sender == beneficiary, "only beneficiary");
        uint256 bal = address(this).balance;
        require(bal > 0, "no balance");
        (bool ok, ) = beneficiary.call{value: bal}("");
        require(ok, "withdraw failed");
    }

    // -------------------------
    // Read helpers
    // -------------------------
    /// Returns small on-chain fingerprint + metadata. Full readable content is in events.
    function read(uint256 pasteId) external view returns (
        bytes32 contentKeccak,
        string memory cid,
        address owner,
        address author,
        uint64 timestamp,
        uint256 donation,
        uint256 upvotes
    ) {
        Meta storage m = meta[pasteId];
        require(m.owner != address(0), "paste not found");
        contentKeccak = contentHash[pasteId];
        cid = attachmentCid[pasteId];
        owner = m.owner;
        author = m.author;
        timestamp = m.timestamp;
        donation = m.donation;
        upvotes = upvoteCount[pasteId];
    }

    function getIdsRange(uint256 fromId, uint256 toId) external view returns (uint256[] memory ids) {
        if (fromId == 0) fromId = 1;
        
        // FIX: Return empty array properly
        if (toId < fromId) return new uint256[](0);

        uint256 last = nextId - 1;
        
        // FIX: Return empty array properly
        if (fromId > last) return new uint256[](0);
        
        if (toId > last) toId = last;

        uint256 len = toId - fromId + 1;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) ids[i] = fromId + i;
    }

    // -------------------------
    // Misc: donations via receive/fallback
    // -------------------------
    receive() external payable {
        totalDonations += msg.value;
    }
    fallback() external payable {
        totalDonations += msg.value;
    }
}
