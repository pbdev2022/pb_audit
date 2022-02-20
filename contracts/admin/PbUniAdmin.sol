// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../errrpt/ErrorReporter.sol";
import "./PBAdminStorage.sol";

contract PBUniAdmin {

    address public admin;
    address public readyAdmin;

    address public nowImpl;
    address public readyImpl;

    event NewReadyImpl(address oldReadyImpl, address newReadyImpl);
    event NewImpl(address oldImpl, address newImpl);
    event NewReadyAdmin(address oldReadyAdmin, address newReadyAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);

    constructor() {
        admin = msg.sender;
    }

    function setReadyImpl(address newReadyImpl) onlyAdmin public {
		require(newReadyImpl != address(0), 'setReadyImpl - Invalid newReadyImpl Err 1');
        require(newReadyImpl != readyImpl, 'setReadyImpl - Invalid newReadyImpl Err 2');
		require(newReadyImpl != nowImpl, 'setReadyImpl - Invalid newReadyImpl Err 3');

        address oldReadyImpl = readyImpl;
        readyImpl = newReadyImpl;

        emit NewReadyImpl(oldReadyImpl, readyImpl);
    }

    function acceptImpl() onlyAdmin public {
		require(readyImpl != address(0), 'acceptImpl - Invalid readyImpl Err 1');
		require(readyImpl != nowImpl, 'acceptImpl - Invalid readyImpl Err 2');
        
        address oldImpl = nowImpl;
        address oldReadyImpl = readyImpl;
        nowImpl = readyImpl;
        readyImpl = address(0);

        emit NewImpl(oldImpl, nowImpl);
        emit NewReadyImpl(oldReadyImpl, readyImpl);
    }

    function setReadyAdmin(address newReadyAdmin) onlyAdmin public {
        require(newReadyAdmin != address(0), 'setReadyAdmin - newReadyAdmin == address(0)');
        require(newReadyAdmin != readyAdmin, 'setReadyAdmin - nnewReadyAdmin == readyAdmin');
        require(newReadyAdmin != admin, 'setReadyAdmin - newReadyAdmin == admin');

        address oldReadyAdmin = readyAdmin;
        readyAdmin = newReadyAdmin;

        emit NewReadyAdmin(oldReadyAdmin, newReadyAdmin);
    }

    function acceptAdmin() onlyAdmin public {
        require(readyAdmin != address(0), 'acceptAdmin - readyAdmin == address(0)');
        require(readyAdmin != admin, 'acceptAdmin - readyAdmin == admin');

        address oldAdmin = admin;
        address oldReadyAdmin = readyAdmin;
        admin = readyAdmin;
        readyAdmin = address(0);

        emit NewAdmin(oldAdmin, admin);
        emit NewReadyAdmin(oldReadyAdmin, readyAdmin);
    }

    fallback () payable external {
        (bool success, ) = nowImpl.delegatecall(msg.data);

        assembly {
              let free_mem_ptr := mload(0x40)
              returndatacopy(free_mem_ptr, 0, returndatasize())

              switch success
              case 0 { revert(free_mem_ptr, returndatasize()) }
              default { return(free_mem_ptr, returndatasize()) }
        }
    }

    receive () payable external {
        revert("PBUniAdmin: Not Supported Method");   
    }

	modifier onlyAdmin() {
		require(msg.sender == admin, 'PBUniAdmin: msg.sender != admin');
		_;
	}    
}
