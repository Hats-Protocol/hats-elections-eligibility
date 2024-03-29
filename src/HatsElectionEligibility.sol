// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule } from "hats-module/HatsModule.sol";
import { HatsEligibilityModule } from "hats-module/HatsEligibilityModule.sol";

/**
 * @title Hats Election Eligibility
 * @author spengrah
 * @author Haberdasher Labs
 * @notice This contract is an eligibility module for Hats protocol. It sets eligibility for a hat
 * based on the results of an election (conducted elsewhere) of a given term.
 * Terms are defined as the timestamp after the term ends. This contract allows for the next term to be set while the
 * current term has not yet ended, which allows for an election for the next term to be conducted while the current term
 * is still active.
 * @dev This contract is designed for instances to be deployed by the HatsModuleFactory.
 */
contract HatsElectionEligibility is HatsEligibilityModule {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error NotBallotBox();
  error NotAdmin();
  error TooManyWinners();
  error ElectionClosed(uint128 termEnd);
  error InvalidTermEnd();
  error NotElected();
  error TermNotEnded();
  error TermEnded();
  error NextTermNotReady();

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event ElectionOpened(uint128 nextTermEnd);

  event ElectionCompleted(uint128 termEnd, address[] winners);

  event NewTermStarted(uint128 termEnd);

  event Recalled(uint128 termEnd, address[] accounts);

  /*//////////////////////////////////////////////////////////////
                            DATA MODELS
  //////////////////////////////////////////////////////////////*/

  /*//////////////////////////////////////////////////////////////
                            CONSTANTS 
  //////////////////////////////////////////////////////////////*/

  /**
   * This contract is a clone with immutable args, which means that it is deployed with a set of
   * immutable storage variables (ie constants). Accessing these constants is cheaper than accessing
   * regular storage variables (such as those set on initialization of a typical EIP-1167 clone),
   * but requires a slightly different approach since they are read from calldata instead of storage.
   *
   * Below is a table of constants and their location.
   *
   * For more, see here: https://github.com/Saw-mon-and-Natalie/clones-with-immutable-args
   *
   * ----------------------------------------------------------------------+
   * CLONE IMMUTABLE "STORAGE"                                             |
   * ----------------------------------------------------------------------|
   * Offset  | Constant          | Type    | Length  | Source              |
   * ----------------------------------------------------------------------|
   * 0       | IMPLEMENTATION    | address | 20      | HatsModule          |
   * 20      | HATS              | address | 20      | HatsModule          |
   * 40      | hatId             | uint256 | 32      | HatsModule          |
   * 72      | BALLOT_BOX_HAT    | uint256 | 32      | this                |
   * 104     | ADMIN_HAT         | uint256 | 32      | this                |
   * ----------------------------------------------------------------------+
   */

  /**
   * @notice The wearer(s) of this hat are authorized to submit election results
   * @dev They are trusted to only submit results for the next election term when appropriate, ie not before the dates
   *  for the next term have been finalized
   */
  function BALLOT_BOX_HAT() public pure returns (uint256) {
    return _getArgUint256(72);
  }

  /// @notice The wearer(s) of this hat are authorized to set the next election term
  /// @dev If 0, the admin(s) of the {hatId} are instead authorized
  function ADMIN_HAT() public pure returns (uint256) {
    return _getArgUint256(104);
  }

  /*//////////////////////////////////////////////////////////////
                            MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  mapping(uint128 termEnd => mapping(address candidates => bool elected)) public electionResults;

  mapping(uint128 termEnd => bool isElectionOpen) public electionStatus;

  /// @notice The first second after the current term ends.
  /// @dev Also serves as the id for the current term
  uint128 public currentTermEnd;

  /// @notice The first second after the next term ends
  /// @dev Also serves as the id for the next term
  uint128 public nextTermEnd;

  /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Deploy the implementation contract and set its version
  /// @dev This is only used to deploy the implementation contract, and should not be used to deploy clones
  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                            INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsModule
  function _setUp(bytes calldata _initData) internal override {
    // decode init data
    (uint128 firstTermEnd) = abi.decode(_initData, (uint128));

    // set currentTermEnd
    currentTermEnd = firstTermEnd;

    // open the first election
    electionStatus[firstTermEnd] = true;

    // log the first term
    emit ElectionOpened(firstTermEnd);
  }

  /*//////////////////////////////////////////////////////////////
                      HATS ELIGIBILITY FUNCTION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsEligibilityModule
  function getWearerStatus(address _wearer, uint256 /* _hatId */ )
    public
    view
    override
    returns (bool eligible, bool standing)
  {
    /// @dev This eligibility module is not concerned with standing, so we default it to good standing
    standing = true;

    uint128 current = currentTermEnd; // save SLOAD

    if (block.timestamp < current) {
      // if the current term is still open, the wearer is eligible if they have been elected for the current term
      eligible = electionResults[current][_wearer];
    }
    // if the current term is closed, the wearer is not eligible
  }

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Submit the results of an election for a specified term, making a set of `_winners` eligible for the hat
   * within that term. This will close the election for that term.
   * @dev Only callable by the wearer(s) of the BALLOT_BOX_HAT.
   *  Will revert if the election for the specified term is closed.
   * @param _termEnd The id of the term for which the election results are being submitted
   * @param _winners The addresses of the winners of the election
   */
  function elect(uint128 _termEnd, address[] calldata _winners) external {
    // caller must be wearing the ballot box hat
    _checkBallotBox(msg.sender);

    // number of winners cannot exceed the maxSupply of {hatId}
    if (_winners.length > HATS().getHatMaxSupply(hatId())) revert TooManyWinners();

    // results can only be submitted for open elections
    if (!electionStatus[_termEnd]) revert ElectionClosed(_termEnd);

    // close the election
    electionStatus[_termEnd] = false;

    // set the election results
    for (uint256 i; i < _winners.length;) {
      electionResults[_termEnd][_winners[i]] = true;

      unchecked {
        ++i;
      }
    }

    // log the election results
    emit ElectionCompleted(_termEnd, _winners);
  }

  /**
   * @notice Submit the results of a recall election for a specified term, making a set of `_recallees` ineligible for
   * the hat during that term.
   * @dev Only callable by the wearer(s) of the BALLOT_BOX_HAT.
   * @param _termEnd The id of the term for which the election results are being submitted, as the termEnd
   * @param _recallees The addresses of the winners of the election
   */
  function recall(uint128 _termEnd, address[] calldata _recallees) external {
    // caller must be wearing the ballot box hat
    _checkBallotBox(msg.sender);

    // loop through the accounts and set their election status to false
    for (uint256 i; i < _recallees.length;) {
      electionResults[_termEnd][_recallees[i]] = false;

      unchecked {
        ++i;
      }
    }

    emit Recalled(_termEnd, _recallees);
  }

  /**
   * @notice Set the next term. This will open the election for the next term. If the next term has already been set and
   * is still open, this function can be used to change it.
   * @dev Only callable by the wearer(s) of the OWNER_HAT.
   *  Will revert if the next term has already been set and is closed.
   * @param _newTermEnd The id of the term that will be opened
   */
  function setNextTerm(uint128 _newTermEnd) external {
    // caller must be wearing the owner hat
    _checkAdmin(msg.sender);

    // new term must end after current term
    if (_newTermEnd <= currentTermEnd) revert InvalidTermEnd();

    // if next term is already set, its election must still be open
    uint128 next = nextTermEnd;
    if (next > 0 && !electionStatus[next]) revert ElectionClosed(next);

    // set the next term
    nextTermEnd = _newTermEnd;

    // open the next election
    electionStatus[_newTermEnd] = true;

    // log the new term
    emit ElectionOpened(_newTermEnd);
  }

  /**
   * @notice Start the next term. This will set the current term to the next term, and clear the next term.
   * @dev Will revert if the current term is not over, if the next term has not been set, or if the next term's election
   * has not closed. Because of these protections, this function can be called by anyone.
   */
  function startNextTerm() external {
    // current term must be over
    if (block.timestamp < currentTermEnd) revert TermNotEnded();

    uint128 next = nextTermEnd; // save SLOADs

    // next term must be set and its election must be closed
    if (next == 0 || electionStatus[next]) revert NextTermNotReady();

    // set the current term to the next term
    currentTermEnd = next;

    // clear the next term
    nextTermEnd = 0;

    // log the change
    emit NewTermStarted(next);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev If {ADMIN_HAT} is non-zero, check if if `_account` is wearing it.
  /// Else, check if `_account` is wearing an admin hat of the {hatId}.
  /// Revert if neither is true.
  function _checkAdmin(address _account) internal view {
    if (ADMIN_HAT() == 0) {
      if (!HATS().isAdminOfHat(_account, hatId())) revert NotAdmin();
    } else {
      if (!HATS().isWearerOfHat(_account, ADMIN_HAT())) revert NotAdmin();
    }
  }

  /// @dev Revert if `_account` is not wearing the BALLOT_BOX_HAT
  function _checkBallotBox(address _account) internal view {
    if (!HATS().isWearerOfHat(_account, BALLOT_BOX_HAT())) revert NotBallotBox();
  }
}
