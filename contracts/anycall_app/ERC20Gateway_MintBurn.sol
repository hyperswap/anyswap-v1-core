// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IAnycallV6Proxy {
    function context() external returns (address from, uint256 fromChainID, uint256 nonce);

    function anyCall(
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _toChainID,
        uint256 _flags
    ) external payable;
}

contract Administrable {
    address public admin;
    address public pendingAdmin;
    event LogSetAdmin(address admin);
    event LogTransferAdmin(address oldadmin, address newadmin);
    event LogAcceptAdmin(address admin);

    function setAdmin(address admin_) internal {
        admin = admin_;
        emit LogSetAdmin(admin_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        address oldAdmin = pendingAdmin;
        pendingAdmin = newAdmin;
        emit LogTransferAdmin(oldAdmin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin);
        admin = pendingAdmin;
        emit LogAcceptAdmin(admin);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }
}

abstract contract AnyCallApp is Administrable {
    uint256 public constant FLAG_PAY_FEE_ON_SRC = 0x1 << 1;
    address public anyCallProxy;
    address public anyCallExecutor;

    mapping(uint256 => address) public peer;

    modifier onlyExecutor() {
        require(msg.sender == anyCallExecutor);
        _;
    }

    constructor (address anyCallProxy_, address anyCallExecutor_) {
        anyCallProxy = anyCallProxy_;
        anyCallExecutor = anyCallExecutor_;
    }

    function setPeers(uint256[] memory chainIDs, address[] memory  peers) public onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
        }
    }

    function setAnyCallProxy(address proxy) public onlyAdmin {
        anyCallProxy = proxy;
    }

    function setAnyCallExecutor(address executor) public onlyAdmin {
        anyCallExecutor = executor;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal virtual returns (bool success, bytes memory result);

    function _anyFallback(bytes calldata data) internal virtual;

    function _anyCall(address _to, bytes memory _data, address _fallback, uint256 _toChainID) internal {
        IAnycallV6Proxy(anyCallProxy).anyCall{value: msg.value}(_to, _data, _fallback, _toChainID, FLAG_PAY_FEE_ON_SRC);
    }

    function anyExecute(bytes calldata data) external onlyExecutor returns (bool success, bytes memory result) {
        (address callFrom, uint256 fromChainID,) = IAnycallV6Proxy(anyCallProxy).context();
        require(peer[fromChainID] == callFrom, "call not allowed");
        _anyExecute(fromChainID, data);
    }

    function anyFallback(address to, bytes calldata data) external onlyExecutor {
        _anyFallback(data);
    }
}

// interface of ERC20Gateway
interface IERC20Gateway {
    function name() external view returns (string memory);
    function token() external view returns (address);
    function getPeer(uint256 foreignChainID) external view returns (address);
    function Swapout(uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
    function Swapout_no_fallback(uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
}

interface IDecimal {
    function decimals() external view returns (uint8);
}

abstract contract ERC20Gateway is IERC20Gateway, AnyCallApp {
    address public token;
    mapping(uint256 => uint8) public decimals;
    uint256 public swapoutSeq;
    string public name;

    constructor (address anyCallProxy, address anyCallExecutor) AnyCallApp(anyCallProxy, anyCallExecutor) {
        setAdmin(msg.sender);
    }

    function getPeer(uint256 foreignChainID) external view returns (address) {
        return peer[foreignChainID];
    }

    function _swapout(uint256 amount, address sender) external virtual returns (bool);
    function _swapin(uint256 amount, address receiver) external virtual returns (bool);
    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) external virtual returns (bool);

    event LogAnySwapOut(uint256 amount, address sender, address receiver, uint256 toChainID, uint256 swapoutSeq);

    function setForeignGateway(uint256[] memory chainIDs, address[] memory  peers, uint8[] memory decimals) external onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
            decimals[chainIDs[i]] = decimals[i];
        }
    }

    function decimal(uint256 chainID) external view returns(uint8) {
        return (decimals[chainID] > 0 ? decimals[chainID] : IDecimal(token).decimals());
    }

    function convertDecimal(uint256 fromChain, uint256 amount) public view returns (uint256) {
        uint8 d_0 = this.decimal(fromChain);
        uint8 d_1 = IDecimal(token).decimals();
        if (d_0 > d_1) {
            for (uint8 i = 0; i < (d_0 - d_1); i++) {
                amount = amount / 10;
            }
        } else {
            for (uint8 i = 0; i < (d_1 - d_0); i++) {
                amount = amount * 10;
            }
        }
        return amount;
    }

    function Swapout(uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        require(this._swapout(amount, msg.sender));
        swapoutSeq++;
        bytes memory data = abi.encode(amount, msg.sender, receiver, swapoutSeq);
        _anyCall(peer[destChainID], data, address(this), destChainID);
        emit LogAnySwapOut(amount, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function Swapout_no_fallback(uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        require(this._swapout(amount, msg.sender));
        swapoutSeq++;
        bytes memory data = abi.encode(amount, msg.sender, receiver, swapoutSeq);
        _anyCall(peer[destChainID], data, address(0), destChainID);
        emit LogAnySwapOut(amount, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal override returns (bool success, bytes memory result) {
        (uint256 amount, , address receiver,) = abi.decode(
            data,
            (uint256, address, address, uint256)
        );
        amount = convertDecimal(fromChainID, amount);
        require(this._swapin(amount, receiver));
    }

    function _anyFallback(bytes calldata data) internal override {
        (uint256 amount, address sender, , uint256 swapoutSeq) = abi.decode(
            data,
            (uint256, address, address, uint256)
        );
        require(this._swapoutFallback(amount, sender, swapoutSeq));
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != 0x0 && codehash != accountHash);
    }
}

interface IGatewayClient {
    function notifySwapoutFallback(bool refundSuccess, uint256 amount, uint256 swapoutSeq) external returns (bool);
}

interface IMintBurn {
    function mint(address account, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    // function burn(address account, uint256 amount) external;
}

contract ERC20Gateway_MintBurn is ERC20Gateway {
    using Address for address;

    constructor (address anyCallProxy, address anyCallExecutor) ERC20Gateway(anyCallProxy, anyCallExecutor) {}

    function _swapout(uint256 amount, address sender) external override returns (bool) {
        try IMintBurn(token).burnFrom(sender, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _swapin(uint256 amount, address receiver) external override returns (bool) {
        try IMintBurn(token).mint(receiver, amount) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) external override returns (bool result) {
        try IMintBurn(token).mint(sender, amount) {
            result = true;
        } catch {
            result = false;
        }
        if (sender.isContract()) {
            try IGatewayClient(sender).notifySwapoutFallback(result, amount, swapoutSeq) returns (bool) {

            } catch {

            }
        }
        return result;
    }
}