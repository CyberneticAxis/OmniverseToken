// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


interface OmniAdaptive {
    function transferOmni(address from, address to, uint256 amount) external;
}


contract Omniverse is ERC20, AccessControl {
    bytes32 public constant RESUPPLIER_ROLE = keccak256("RESUPPLIER_ROLE");

    uint256 public constant INITIAL_TOKEN_SUPPLY = 4 * 10**9 * 10**18;

    OmniAdaptive public omniAdaptive;

    /// @param ownerAddr The multisig address
    constructor(address ownerAddr) ERC20("Omniverse", "OMNI") {
        require(ownerAddr != address(0x0), "Owner can't be 0x0");

        _grantRole(DEFAULT_ADMIN_ROLE, ownerAddr);
        _grantRole(RESUPPLIER_ROLE, ownerAddr);

        // Initial token supply is sent to the non-multisig address to allow creating
        // LP. The remaining tokens will be sent to the multisig address or locked up
        // after the fact.
        _mint(msg.sender, INITIAL_TOKEN_SUPPLY);
    }

    function omniAdaptiveTransfer(address from, address to, uint256 amount) external {
        require(msg.sender == address(omniAdaptive), "Can only be called by OmniAdaptive");
        ERC20._transfer(from, to, amount);
    }

    function resupply(address recipient, uint256 amount) external onlyRole(RESUPPLIER_ROLE) {
        _mint(recipient, amount);
    }

    function setOmniAdaptive(address omniAdaptiveAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        omniAdaptive = OmniAdaptive(omniAdaptiveAddr);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        omniAdaptive.transferOmni(from, to, amount);
    }
}