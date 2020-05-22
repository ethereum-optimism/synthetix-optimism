pragma solidity ^0.5.16;

import "./Owned.sol";
import "./MixinResolver.sol";
import "./SafeDecimalMath.sol";
import "./BinaryOptionMarketFactory.sol";
import "./BinaryOption.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IFeePool.sol";

// TODO: Tests for claimablyBy, totalClaimable, balancesOf, totalSupplies, totalExercisable
// TODO: MixinResolver for factory itself + the ability to switch factories/owners
// TODO: Oracle failure (move to 2.0).
// TODO: Interfaces

contract BinaryOptionMarket is Owned, MixinResolver {

    /* ========== LIBRARIES ========== */

    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== TYPES ========== */

    enum Phase { Bidding, Trading, Maturity, Destruction }
    enum Result { Long, Short }

    /* ========== STATE VARIABLES ========== */

    // Related contracts
    address public creator;
    BinaryOptionMarketFactory public factory;

    // Options and prices
    BinaryOption public longOption;
    BinaryOption public shortOption;
    uint256 public longPrice;
    uint256 public shortPrice;

    // Deposits
    // We track the sum of open bids on short and long, plus withheld refund fees.
    // We must keep this explicitly, in case tokens are transferred to this contract directly.
    uint256 public deposited;
    uint256 public minimumInitialLiquidity;

    // Dates and Times
    uint256 public endOfBidding;
    uint256 public maturity;
    uint256 public destruction;

    // Oracle and resolution details
    bytes32 public oracleKey;
    uint256 public targetOraclePrice;
    uint256 public finalOraclePrice;
    uint256 public oracleMaturityWindow;
    bool public resolved;

    // Fees
    uint256 public poolFee;
    uint256 public creatorFee;
    uint256 public refundFee;
    uint256 public creatorFeesCollected;
    uint256 public poolFeesCollected;

    /* ---------- Address Resolver Configuration ---------- */

    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_SYNTHSUSD = "SynthsUSD";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    bytes32[24] private addressesToCache = [
        CONTRACT_EXRATES,
        CONTRACT_SYNTHSUSD,
        CONTRACT_FEEPOOL
    ];

    /* ========== CONSTRUCTOR ========== */

    constructor(address _resolver,
                uint256 _endOfBidding, uint256 _maturity, uint256 _destruction,
                bytes32 _oracleKey,
                uint256 _targetOraclePrice,
                uint256 _oracleMaturityWindow,
                uint256 _minimumInitialLiquidity,
                address _creator, uint256 longBid, uint256 shortBid,
                uint256 _poolFee, uint256 _creatorFee, uint256 _refundFee
    )
        public
        Owned(msg.sender)
        MixinResolver(_resolver, addressesToCache)
    {
        require(now < _endOfBidding, "End of bidding must be in the future.");
        require(_endOfBidding < _maturity, "Maturity must be after the end of bidding.");
        require(_maturity < _destruction, "Destruction must be after maturity.");
        require(_poolFee.add(_creatorFee) < SafeDecimalMath.unit(), "Fee must be less than 100%.");
        require(_creator != address(0), "Creator must not be the 0 address.");
        require(_refundFee <= SafeDecimalMath.unit(), "Refund fee must be no greater than 100%.");

        // Related contracts
        creator = _creator;
        factory = BinaryOptionMarketFactory(msg.sender);

        // Instantiate the options themselves
        longOption = new BinaryOption(_creator, longBid);
        shortOption = new BinaryOption(_creator, shortBid);

        // Deposits
        // Note that the initial deposit of synths must be made
        // externally by the factory, otherwise the contracts will
        // fall out of sync with reality.
        // Similarly the total system deposits must be updated in the factory.
        uint256 initialDeposit = longBid.add(shortBid);
        require(_minimumInitialLiquidity <= initialDeposit, "Insufficient initial capital provided.");
        minimumInitialLiquidity = _minimumInitialLiquidity;
        deposited = initialDeposit;
        _updatePrices(longBid, shortBid, initialDeposit);

        // Dates and times
        endOfBidding = _endOfBidding;
        maturity = _maturity;
        destruction = _destruction;

        // Oracle and prices
        oracleKey = _oracleKey;
        targetOraclePrice = _targetOraclePrice;
        oracleMaturityWindow = _oracleMaturityWindow;

        // Fees
        poolFee = _poolFee;
        creatorFee = _creatorFee;
        refundFee = _refundFee;
    }

    /* ========== VIEWS ========== */

    /* ---------- External Contracts ---------- */

    function exchangeRates() public view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function synthsUSD() public view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSUSD, "Missing SynthsUSD address"));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL, "Missing FeePool address"));
    }

    /* ---------- Phases ---------- */

    function biddingEnded() public view returns (bool) {
        return endOfBidding <= now;
    }

    function matured() public view returns (bool) {
        return maturity <= now;
    }

    function destructible() public view returns (bool) {
        return destruction <= now;
    }

    function currentPhase() external view returns (Phase) {
        if (!biddingEnded()) {
            return Phase.Bidding;
        }

        if (!matured()) {
            return Phase.Trading;
        }

        if (!destructible()) {
            return Phase.Maturity;
        }

        return Phase.Destruction;
    }

    /* ---------- Market Resolution ---------- */

    function currentOraclePriceAndTimestamp() public view returns (uint256 price, uint256 updatedAt) {
        IExchangeRates exRates = exchangeRates();
        uint256 currentRoundId = exRates.getCurrentRoundId(oracleKey);
        return exRates.rateAndTimestampAtRound(oracleKey, currentRoundId);
    }

    function _withinMaturityWindow(uint256 timestamp) internal view returns (bool) {
        return (maturity - oracleMaturityWindow) <= timestamp;
    }

    function canResolve() external view returns (bool) {
        ( , uint256 updatedAt) = currentOraclePriceAndTimestamp();
        return matured() && _withinMaturityWindow(updatedAt) && !resolved;
    }

    function result() public view returns (Result) {
        uint256 price;
        if (resolved) {
            price = finalOraclePrice;
        } else {
            (price, ) = currentOraclePriceAndTimestamp();
        }

        if (targetOraclePrice <= price) {
            return Result.Long;
        }
        return Result.Short;
    }

    /* ---------- Option Prices ---------- */

    function prices() external view returns (uint256 long, uint256 short) {
        return (longPrice, shortPrice);
    }

    function senderPrice() external view returns (uint256) {
        if (msg.sender == address(longOption)) {
            return longPrice;
        }
        if (msg.sender == address(shortOption)) {
            return shortPrice;
        }
        revert("Message sender is not an option of this market.");
    }

    /* ---------- Option Balances and Bids ---------- */

    function bidsOf(address account) public view returns (uint256 long, uint256 short) {
        return (longOption.bidOf(account), shortOption.bidOf(account));
    }

    function totalBids() external view returns (uint256 long, uint256 short) {
        return (longOption.totalBids(), shortOption.totalBids());
    }

    function claimableBy(address account) public view returns (uint256 long, uint256 short) {
        return (longOption.claimableBy(account), shortOption.claimableBy(account));
    }

    function totalClaimable() external view returns (uint256 long, uint256 short) {
        return (longOption.totalClaimable(), shortOption.totalClaimable());
    }

    function balancesOf(address account) public view returns (uint256 long, uint256 short) {
        return (longOption.balanceOf(account), shortOption.balanceOf(account));
    }

    function totalSupplies() external view returns (uint256 long, uint256 short) {
        return (longOption.totalSupply(), shortOption.totalSupply());
    }

    function totalExercisable() external view returns (uint256 long, uint256 short) {
        return (longOption.totalExercisable(), shortOption.totalExercisable());
    }

    /* ---------- Market Destruction ---------- */

    function _destructionFunds(uint256 _deposited) internal view returns (uint256) {
        uint256 remainder = _deposited.sub(creatorFeesCollected);
        // Unclaimed deposits can be claimed.
        if (remainder > poolFeesCollected) {
            return creatorFeesCollected.add(remainder.sub(poolFeesCollected)) ;
        }
        return creatorFeesCollected;
    }

    function destructionFunds() public view returns (uint256) {
        if (!destructible()) {
            return 0;
        }
        return _destructionFunds(deposited);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /* ---------- Bidding and Refunding ---------- */

    function _updatePrices(uint256 longBids, uint256 shortBids, uint _deposited) internal {
        require(longBids != 0 && shortBids != 0, "Option prices must be nonzero.");
        uint256 feeMultiplier = SafeDecimalMath.unit().sub(poolFee.add(creatorFee));
        uint256 Q = _deposited.multiplyDecimalRound(feeMultiplier);

        // The math library rounds up on an exact half-increment -- the price on one side may be an increment too high,
        // but this only implies a tiny extra quantity will go to fees.
        uint256 _longPrice = longBids.divideDecimalRound(Q);
        uint256 _shortPrice = shortBids.divideDecimalRound(Q);

        longPrice = _longPrice;
        shortPrice = _shortPrice;
        emit PricesUpdated(_longPrice, _shortPrice);
    }

    function _internalBid(uint256 bid, bool long) internal onlyDuringBidding {
        if (bid == 0) {
            return;
        }

        if (long) {
            longOption.bid(msg.sender, bid);
            emit LongBid(msg.sender, bid);
        } else {
            shortOption.bid(msg.sender, bid);
            emit ShortBid(msg.sender, bid);
        }

        uint256 _deposited = deposited.add(bid);
        deposited = _deposited;
        factory.incrementTotalDeposited(bid);
        synthsUSD().transferFrom(msg.sender, address(this), bid);
        _updatePrices(longOption.totalBids(), shortOption.totalBids(), _deposited);
    }

    function bidLong(uint256 bid) external {
        _internalBid(bid, true);
    }

    function bidShort(uint256 bid) external {
        _internalBid(bid, false);
    }

    function _internalRefund(uint256 refund, bool long) internal onlyDuringBidding returns (uint256) {
        if (refund == 0) {
            return 0;
        }

        // If the message sender is the creator, don't let them refund the minimum initial capital.
        if (msg.sender == creator) {
            (uint256 longBid, uint256 shortBid) = bidsOf(msg.sender);
            uint256 creatorCapital = longBid.add(shortBid);
            require(minimumInitialLiquidity <= creatorCapital.sub(refund), "Minimum creator capital requirement violated.");

            // Require the market creator to leave some capital on each side.
            if (long) {
                require(refund < longBid, "Cannot refund entire creator position.");
            } else {
                require(refund < shortBid, "Cannot refund entire creator position.");
            }
        }

        // Safe subtraction here and in related contracts will fail if either the
        // total supply, deposits, or wallet balance are too small to support the refund.
        uint256 refundSansFee = refund.multiplyDecimalRound(SafeDecimalMath.unit().sub(refundFee));

        if (long) {
            longOption.refund(msg.sender, refund);
            emit LongRefund(msg.sender, refundSansFee, refund.sub(refundSansFee));
        } else {
            shortOption.refund(msg.sender, refund);
            emit ShortRefund(msg.sender, refundSansFee, refund.sub(refundSansFee));
        }

        uint256 _deposited = deposited.sub(refundSansFee);
        deposited = _deposited;
        factory.decrementTotalDeposited(refundSansFee);
        synthsUSD().transfer(msg.sender, refundSansFee);
        _updatePrices(longOption.totalBids(), shortOption.totalBids(), _deposited);

        return refundSansFee;
    }

    function refundLong(uint256 refund) external returns (uint256) {
        return _internalRefund(refund, true);
    }

    function refundShort(uint256 refund) external returns (uint256) {
        return _internalRefund(refund, false);
    }

    /* ---------- Market Resolution ---------- */

    function resolve() public onlyAfterMaturity {
        require(!resolved, "The market has already resolved.");

        (uint256 price, uint256 updatedAt) = currentOraclePriceAndTimestamp();

        // We don't need to perform stale price checks, so long as the price was
        // last updated after the maturity date.
        if (!_withinMaturityWindow(updatedAt)) {
            revert("The price was last updated before the maturity window.");
        }

        finalOraclePrice = price;
        resolved = true;

        uint256 _deposited = deposited;
        creatorFeesCollected = _deposited.multiplyDecimalRound(creatorFee);
        poolFeesCollected = _deposited.multiplyDecimalRound(poolFee);

        emit MarketResolved(result(), price, updatedAt);
    }

    /* ---------- Claiming and Exercising Options ---------- */

    function claimOptions() public onlyAfterBidding returns (uint256 longClaimed, uint256 shortClaimed) {
        uint256 longOptions = longOption.claim(msg.sender);
        uint256 shortOptions = shortOption.claim(msg.sender);

        if (longOptions.add(shortOptions) != 0) {
            emit OptionsClaimed(msg.sender, longOptions, shortOptions);
        }

        return (longOptions, shortOptions);
    }

    function exerciseOptions() public returns (uint256) {
        require(resolved, "The market has not yet resolved.");

        // If there are options to be claimed, claim them and proceed.
        (uint256 longClaimable, uint256 shortClaimable) = claimableBy(msg.sender);
        if (longClaimable != 0 || shortClaimable != 0) {
            claimOptions();
        }

        // If the account holds no options, do nothing.
        (uint256 longOptions, uint256 shortOptions) = balancesOf(msg.sender);
        if (longOptions == 0 && shortOptions == 0) {
            return 0;
        }

        // Each option only need to be exercised if the account holds any of it.
        if (longOptions != 0) {
            longOption.exercise(msg.sender);
        }
        if (shortOptions != 0) {
            shortOption.exercise(msg.sender);
        }

        // Only pay out the side that won.
        uint256 payout;
        if (result() == Result.Long) {
            payout = longOptions;
        } else {
            payout = shortOptions;
        }

        emit OptionsExercised(msg.sender, payout);
        if (payout != 0) {
            deposited = deposited.sub(payout);
            factory.decrementTotalDeposited(payout);
            synthsUSD().transfer(msg.sender, payout);
        }
        return payout;
    }

    /* ---------- Market Destruction ---------- */

    function selfDestruct(address payable beneficiary) public onlyFactory {
        require(destructible(), "Market cannot be destroyed yet.");
        require(resolved, "This market has not yet resolved.");

        uint256 _deposited = deposited;
        factory.decrementTotalDeposited(_deposited);
        // And the self destruction implies the corresponding `deposited = 0;`

        // The creator fee, along with any unclaimed funds, will go to the beneficiary.
        // If the quantity remaining is too small or large due to rounding errors or direct transfers,
        // this will affect the pool's fee take.
        ISynth synth = synthsUSD();
        synth.transfer(beneficiary, _destructionFunds(_deposited));
        synth.transfer(feePool().FEE_ADDRESS(), synth.balanceOf(address(this)));

        // Destroy the option tokens before destroying the market itself.
        longOption.selfDestruct(beneficiary);
        shortOption.selfDestruct(beneficiary);

        // Good night
        selfdestruct(beneficiary);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyDuringBidding() {
        require(!biddingEnded(), "Bidding must be active.");
        _;
    }

    modifier onlyAfterBidding() {
        require(biddingEnded(), "Bidding must be complete.");
        _;
    }

    modifier onlyAfterMaturity() {
        require(matured(), "The maturity date has not been reached.");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == address(factory), "Only permitted for the factory.");
        _;
    }

    /* ========== EVENTS ========== */

    event LongBid(address indexed bidder, uint256 bid);
    event ShortBid(address indexed bidder, uint256 bid);
    event LongRefund(address indexed refunder, uint256 refund, uint256 fee);
    event ShortRefund(address indexed refunder, uint256 refund, uint256 fee);
    event PricesUpdated(uint256 longPrice, uint256 shortPrice);
    event MarketResolved(Result result, uint256 oraclePrice, uint256 oracleTimestamp);
    event OptionsClaimed(address indexed claimant, uint256 longOptions, uint256 shortOptions);
    event OptionsExercised(address indexed claimant, uint256 payout);
}
