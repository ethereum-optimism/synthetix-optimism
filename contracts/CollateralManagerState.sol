pragma solidity ^0.5.16;

pragma experimental ABIEncoderV2;

// Inheritance
import "./Owned.sol";
import "./State.sol";
import "./interfaces/ICollateral.sol";

// Libraries
import "./SafeDecimalMath.sol";

contract CollateralManagerState is Owned, State {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    uint public openLoans;
    uint public totalLoans;

    struct balance {
        uint long;
        uint short;
    }

    // The total amount of long and short for a synth,
    mapping(bytes32 => balance) public totalIssuedSynths;

    constructor(address _owner, address _associatedContract) public Owned(_owner) State(_associatedContract) {}

    function long(bytes32 synth) external view onlyAssociatedContract returns (uint) {
        return totalIssuedSynths[synth].long;
    }

    function short(bytes32 synth) external view onlyAssociatedContract returns (uint) {
        return totalIssuedSynths[synth].short;
    } 

    function incrementTotalLoans() external onlyAssociatedContract returns (uint) {
        openLoans = openLoans.add(1);
        totalLoans = totalLoans.add(1);
        // Return total count to be used as a unique ID.
        return totalLoans;
    }


    function incrementLongs(bytes32 synth, uint256 amount) external onlyAssociatedContract {
        totalIssuedSynths[synth].long = totalIssuedSynths[synth].long.add(amount);
    }

    function decrementLongs(bytes32 synth, uint256 amount) external onlyAssociatedContract {
        totalIssuedSynths[synth].long = totalIssuedSynths[synth].long.sub(amount);
    }

    function incrementShorts(bytes32 synth, uint256 amount) external onlyAssociatedContract {
        totalIssuedSynths[synth].short = totalIssuedSynths[synth].short.add(amount);
    }

    function decrementShorts(bytes32 synth, uint256 amount) external onlyAssociatedContract {
        totalIssuedSynths[synth].short = totalIssuedSynths[synth].short.sub(amount);
    }
}