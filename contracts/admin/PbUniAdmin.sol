// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../errrpt/ErrorReporter.sol";
import "./PBAdminStorage.sol";

contract PbUniAdmin is PbUniAdminAdminStorage, PBAdminErrorReporter {

    event NewPendingImplementation(address oldPendingImplementation, address newPendingImplementation);
    event NewImplementation(address oldImplementation, address newImplementation);
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);

    constructor() {
        admin = msg.sender;
    }

    function _setPendingImplementation(address newPendingImplementation) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_IMPLEMENTATION_OWNER_CHECK);
        }

        address oldPendingImplementation = pendingPBAdminImplementation;
        pendingPBAdminImplementation = newPendingImplementation;

        emit NewPendingImplementation(oldPendingImplementation, pendingPBAdminImplementation);

        return uint(Error.NO_ERROR);
    }

    function _acceptImplementation() public returns (uint) {
        if (msg.sender != pendingPBAdminImplementation || pendingPBAdminImplementation == address(0)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.ACCEPT_PENDING_IMPLEMENTATION_ADDRESS_CHECK);
        }

        address oldImplementation = pbAdminImplementation;
        address oldPendingImplementation = pendingPBAdminImplementation;
        pbAdminImplementation = pendingPBAdminImplementation;
        pendingPBAdminImplementation = address(0);

        emit NewImplementation(oldImplementation, pbAdminImplementation);
        emit NewPendingImplementation(oldPendingImplementation, pendingPBAdminImplementation);

        return uint(Error.NO_ERROR);
    }

    function _setPendingAdmin(address newPendingAdmin) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }

        address oldPendingAdmin = pendingAdmin;
        pendingAdmin = newPendingAdmin;

        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return uint(Error.NO_ERROR);
    }

    function _acceptAdmin() public returns (uint) {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK);
        }

        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;
        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return uint(Error.NO_ERROR);
    }

    fallback () payable external {
        (bool success, ) = pbAdminImplementation.delegatecall(msg.data);

        assembly {
              let free_mem_ptr := mload(0x40)
              returndatacopy(free_mem_ptr, 0, returndatasize())

              switch success
              case 0 { revert(free_mem_ptr, returndatasize()) }
              default { return(free_mem_ptr, returndatasize()) }
        }
    }

    receive () payable external {
        revert("Not Supported Method");   
    }
}
