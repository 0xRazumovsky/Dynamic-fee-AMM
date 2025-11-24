// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title TWAP + Volatility Oracle (sampled, circular buffer)
/// @notice Production-ready-ish example: stores price cumulative values (WAD * seconds) into
/// a fixed-size circular buffer of samples. Anyone can call `update` but updates are guarded
/// by `maxDeltaSeconds` and `maxRelativePriceChangeWAD`. Keepers can post an authoritative
/// volatility value on-chain via `postVolatility`.
///
/// Design notes:
/// - Price input is expected as WAD (1e18); priceCumulative is priceWAD * timeSeconds and
///   grows monotonically.
/// - When enough time passes (>= sampleInterval) `update` writes a new sample into the
///   circular buffer and advances the cursor.
/// - `getTWAP(periodSeconds)` requires period to be a multiple of sampleInterval (cheap)
///   and computes (cum_now - cum_past) / periodSeconds.
/// - On-chain volatility is an approximation (average absolute returns between consecutive
///   samples) — relatively cheap and usable for basic checks.
///
/// Security notes:
/// - Guards on maxDeltaSeconds and maxRelativePriceChangeWAD to avoid price flash attacks
///   from malicious relayers.
/// - Uses custom errors to save gas.

contract TWAPOracle is Ownable {
    using PRBMath for uint256;
    uint256 public constant WAD = 1e18;

    struct Sample {
        uint256 cumulative; // priceWAD * timestampSeconds
        uint32 timestamp; // unix seconds
    }

    // Circular buffer of samples (mapping for fixed capacity/storage safety)
    mapping(uint16 => Sample) public samples;
    uint16 public sampleCount; // capacity
    uint32 public sampleInterval; // seconds between samples
    uint16 public sampleCursor; // next write index

    // cumulative price state
    uint256 public priceCumulativeLast; // WAD * seconds
    uint32 public blockTimestampLast;

    // volatility posted by keepers
    uint256 public lastPostedVolWAD;
    uint32 public lastPostedVolTimestamp;

    // guards
    uint32 public maxDeltaSeconds; // e.g., 3600
    uint256 public maxRelativePriceChangeWAD; // e.g., 2e18 for 2x

    // keeper ACL
    mapping(address => bool) public keepers;

    // Events
    event TWAPUpdated(uint256 cumulative, uint32 timestamp);
    event VolatilityPosted(uint256 volWAD, uint32 timestamp, address indexed keeper);
    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);

    // Errors (short, gas-efficient)
    error ZeroInterval();
    error ZeroSampleCount();
    error StaleSample();
    error TooLargeDelta(uint32 delta, uint32 max);
    error PriceSpike(uint256 oldPriceWAD, uint256 newPriceWAD, uint256 maxRelWAD);
    error UnauthorizedKeeper(address caller);
    error PeriodNotMultiple(uint32 period, uint32 interval);
    error NotEnoughSamples(uint256 required, uint256 available);

    /// @param _sampleInterval seconds between stored samples (e.g. 60)
    /// @param _sampleCount number of samples stored in circular buffer (e.g. 30)
    /// @param _maxDeltaSeconds maximum seconds allowed between updates (protects against huge warps)
    /// @param _maxRelativePriceChangeWAD maximum relative price jump allowed (WAD, e.g. 2e18 = 2x)
    constructor(uint32 _sampleInterval, uint16 _sampleCount, uint32 _maxDeltaSeconds, uint256 _maxRelativePriceChangeWAD) {
        if (_sampleInterval == 0) revert ZeroInterval();
        if (_sampleCount == 0) revert ZeroSampleCount();
        sampleInterval = _sampleInterval;
        sampleCount = _sampleCount;
        maxDeltaSeconds = _maxDeltaSeconds;
        maxRelativePriceChangeWAD = _maxRelativePriceChangeWAD;

    // nothing else to init for mapping-backed ring buffer
    }

    // ------------------ Keeper management ------------------
    /// @notice Add a keeper address. Only owner can call.
    function addKeeper(address k) external onlyOwner {
        keepers[k] = true;
        emit KeeperAdded(k);
    }

    /// @notice Remove a keeper. Only owner can call.
    function removeKeeper(address k) external onlyOwner {
        delete keepers[k];
        emit KeeperRemoved(k);
    }

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert UnauthorizedKeeper(msg.sender);
        _;
    }

    // ------------------ Update & samples ------------------
    /// @notice Update the oracle with the current (off-chain) observed price in WAD.
    /// @dev Anyone can call, but values are guarded. Emits TWAPUpdated when a sample is written.
    ///      Calls are idempotent for the same block timestamp.
    /// @param priceNowWAD price in WAD (1e18)
    function update(uint256 priceNowWAD) external {
        uint32 ts = uint32(block.timestamp);

        if (blockTimestampLast == 0) {
            // first-time init
            blockTimestampLast = ts;
            priceCumulativeLast = 0;
            // no cumulative increase because no prior timestamp
        }

        uint32 delta = ts - blockTimestampLast;
        if (delta == 0) return; // nothing to do

        if (maxDeltaSeconds != 0 && delta > maxDeltaSeconds) revert TooLargeDelta(delta, maxDeltaSeconds);

        // Guard on relative price change compared to implied last price.
        // We can compute implied last price if we had recent samples; if none, only accept any price.
        uint256 impliedPriceWAD = _lastImpliedPriceWAD();
        if (impliedPriceWAD != 0 && maxRelativePriceChangeWAD != 0) {
            // check new/old <= maxRel
            // i.e., priceNowWAD <= impliedPriceWAD * maxRelativePriceChangeWAD / WAD
            uint256 maxAllowed = (impliedPriceWAD * maxRelativePriceChangeWAD) / WAD;
            if (priceNowWAD > maxAllowed) revert PriceSpike(impliedPriceWAD, priceNowWAD, maxRelativePriceChangeWAD);
        }

        // accumulate price*time (priceWAD * seconds). Product is safe for normal prices and intervals.
        uint256 add = priceNowWAD * delta;
        unchecked { priceCumulativeLast += add; }
        blockTimestampLast = ts;

        // if enough time since last stored sample, store a sample (may store multiple if caller is very late)
        // compute how many intervals passed since the most recent sample timestamp available
        uint32 lastSampleTs = _lastSampleTimestamp();
        // if lastSampleTs == 0, then no samples stored yet -- we'll write the initial sample now
        uint32 since = lastSampleTs == 0 ? delta : ts - lastSampleTs;
        if (since >= sampleInterval) {
            // number of full samples to store
            uint32 n = since / sampleInterval;
            // write up to sampleCount entries (older ones overwritten)
            for (uint32 i = 0; i < n; ++i) {
                // time for this sample = ts - (since - (i+1)*sampleInterval)
                uint32 sampleTs = ts - (since - (i+1) * sampleInterval);
                // cumulative at that time: approximate by linear interpolation over the last delta window.
                // For simplicity we store the current cumulative (this biases recent samples slightly if delayed)
                samples[sampleCursor] = Sample({ cumulative: priceCumulativeLast, timestamp: sampleTs });
                // advance cursor
                sampleCursor = uint16((sampleCursor + 1) % sampleCount);
                emit TWAPUpdated(priceCumulativeLast, sampleTs);
            }
        }
    }

    /// @notice Returns TWAP in WAD for a requested period. Requires periodSeconds to be multiple of sampleInterval.
    /// @dev Cheap implementation: requires periodSeconds % sampleInterval == 0. If you want interpolation, extend this.
    function getTWAP(uint32 periodSeconds) external view returns (uint256 twapWAD) {
        if (periodSeconds == 0) revert PeriodNotMultiple(periodSeconds, sampleInterval);
        if (periodSeconds % sampleInterval != 0) revert PeriodNotMultiple(periodSeconds, sampleInterval);
        uint32 steps = periodSeconds / sampleInterval;
        if (steps == 0) revert PeriodNotMultiple(periodSeconds, sampleInterval);

        uint16 filled = _filledSamples();
        if (uint32(filled) < steps) revert NotEnoughSamples(steps, filled);

        // last written index is cursor-1
        uint16 lastIdx = sampleCursor == 0 ? sampleCount - 1 : sampleCursor - 1;
        uint32 lastIdx32 = uint32(lastIdx);
        uint32 sc = uint32(sampleCount);
        uint16 pastIdx;
        if (lastIdx32 >= steps) {
            pastIdx = uint16(lastIdx32 - steps);
        } else {
            pastIdx = uint16(sc - (steps - lastIdx32));
        }

        Sample memory last = samples[lastIdx];
        Sample memory past = samples[pastIdx];

        // sanity
        if (last.timestamp <= past.timestamp) revert StaleSample();

        uint32 deltaT = last.timestamp - past.timestamp;
        // (last.cumulative - past.cumulative) / deltaT -> returns priceWAD
        uint256 cumDelta = last.cumulative - past.cumulative;
        // Use straightforward division; cumDelta is priceWAD * seconds
        twapWAD = cumDelta / deltaT;
    }

    // ------------------ Volatility ------------------
    /// @notice Keepers post an externally computed volatility (WAD) for quick on-chain access.
    function postVolatility(uint256 volWAD) external onlyKeeper {
        lastPostedVolWAD = volWAD;
        lastPostedVolTimestamp = uint32(block.timestamp);
        emit VolatilityPosted(volWAD, lastPostedVolTimestamp, msg.sender);
    }

    /// @notice On-chain approximate volatility estimator: average absolute returns between consecutive samples
    /// @param lookbackSamples how many consecutive sample intervals to include (must be >=2)
    /// @dev This is a low-cost approximation and not a substitute for off-chain computed realized vol.
    function getVolatilityOnchain(uint32 lookbackSamples) external view returns (uint256 volWAD) {
        if (lookbackSamples < 2) return 0;
        uint16 filled = _filledSamples();
        if (filled < lookbackSamples) revert NotEnoughSamples(lookbackSamples, filled);

        // build price list per interval from samples (TWAP per interval)
        uint16 lastIdx = sampleCursor == 0 ? sampleCount - 1 : sampleCursor - 1;
        uint32 lastIdx32 = uint32(lastIdx);
        uint32 sc = uint32(sampleCount);
        uint256 sumAbsReturnWAD = 0;
        uint256 prevPriceWAD = 0;
        for (uint32 i = 0; i < lookbackSamples; ++i) {
            uint32 idx32;
            if (lastIdx32 >= i) idx32 = lastIdx32 - i;
            else idx32 = sc - (i - lastIdx32);
            uint16 idx = uint16(idx32);
            Sample memory s = samples[idx];
            // we cannot compute interval TWAP without previous sample, so skip last element when i==lookbackSamples-1
            if (i == lookbackSamples - 1) {
                // last element is the oldest; store its implied price for next iteration
                // implied price for a sample equals cum_delta / sampleInterval if previous sample exists
                // but in this loop we will compute returns from newer to older; just capture prevPriceWAD later
                // We set prevPriceWAD in next loop iteration when we have two samples
            }
            // to get priceWAD for sample at idx we need previous sample
            uint16 prevIdx = idx == 0 ? uint16(sampleCount - 1) : idx - 1;
            Sample memory prevS = samples[prevIdx];
            if (s.timestamp <= prevS.timestamp) continue; // skip invalid
            uint256 priceWAD = (s.cumulative - prevS.cumulative) / (s.timestamp - prevS.timestamp);
            if (prevPriceWAD != 0) {
                // abs((price - prev)/prev)
                uint256 diff = priceWAD > prevPriceWAD ? priceWAD - prevPriceWAD : prevPriceWAD - priceWAD;
                // return in WAD: diff * WAD / prevPriceWAD
                uint256 absReturnWAD = (diff * WAD) / prevPriceWAD;
                sumAbsReturnWAD += absReturnWAD;
            }
            prevPriceWAD = priceWAD;
        }
        // number of returns computed is lookbackSamples-1
        volWAD = sumAbsReturnWAD / (lookbackSamples - 1);
    }

    // ------------------ Helpers ------------------
    function _lastSampleTimestamp() internal view returns (uint32) {
        uint16 lastIdx = sampleCursor == 0 ? sampleCount - 1 : sampleCursor - 1;
        return samples[lastIdx].timestamp;
    }

    function _filledSamples() internal view returns (uint16) {
        // count non-zero timestamps in buffer (cheap scan up to sampleCount)
        uint16 filled = 0;
        for (uint16 i = 0; i < sampleCount; ++i) {
            if (samples[i].timestamp != 0) filled++;
        }
        return filled;
    }

    /// @notice Try to infer an implied price from the two most recent samples (WAD). Returns 0 if not possible.
    function _lastImpliedPriceWAD() internal view returns (uint256) {
        uint16 filled = _filledSamples();
        if (filled == 0) return 0;
        if (filled == 1) return 0;
        uint16 lastIdx = sampleCursor == 0 ? sampleCount - 1 : sampleCursor - 1;
        uint16 prevIdx = lastIdx == 0 ? sampleCount - 1 : lastIdx - 1;
        Sample memory last = samples[lastIdx];
        Sample memory prev = samples[prevIdx];
        if (last.timestamp <= prev.timestamp) return 0;
        uint32 dt = last.timestamp - prev.timestamp;
        if (dt == 0) return 0;
        return (last.cumulative - prev.cumulative) / dt;
    }
}
