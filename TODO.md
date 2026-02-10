## Testing (✓ Completed)

### Test Organization
- **Unit tests** (`zig build test`): 59 tests, fast (70ms), no C dependencies
  - Image operations (18 tests)
  - PNG encoding/streaming (10 tests)
  - JPEG behavioral tests (12 tests)
  - Error handling (19 tests)
- **Integration tests** (`zig build integration-test`): 11 tests, with stb_image comparison
  - PNG comparison (7 tests)
  - JPEG comparison (4 tests)
- **All tests** (`zig build test-all`): 70 total tests

### Test Coverage
✓ Output correctness (pixel-perfect comparison vs stb_image)
✓ Behavioral tests (dimensions, channels, memory allocation)
✓ Error handling (invalid signatures, truncated files, corrupt data)
✓ Edge cases (empty files, zero dimensions, unsupported formats)

## Progressive JPEG Support (✓ Fully Implemented)

### ✓ Implemented Features
- SOF2 marker parsing (progressive JPEG detection)
- Coefficient buffer allocation and management
- DC first scan decoding (spec_start=0, spec_end=0, succ_high=0)
- DC refinement scans (succ_high > 0)
- AC first scan decoding (spec_start>0, succ_high=0) for both interleaved and non-interleaved
- AC refinement scans (succ_high > 0) with proper bit manipulation
- **Non-interleaved AC scan support** (one component per scan)
- Component tracking per scan (which components are in each SOS)
- Finalization: dequantize + IDCT all blocks after EOI marker
- Multi-scan support (continue parsing after SOS, finalize at EOI)
- Memory cleanup on error (no leaks)
- Restart marker handling (DC predictor + EOB run reset)

### Image Quality
- **Baseline JPEG**: Pixel-perfect match with stb_image (max diff ≤ 3)
- **Progressive JPEG**: Pixel-perfect match with stb_image (max diff = 0)
  - All refinement scans properly decoded
  - Successive approximation correctly implemented
  - Tested with real-world progressive JPEGs (960x540 image)

### Implementation Details
- DC refinement: Read 1 bit and add/subtract at bit position Al
- AC refinement: Complex "advance by r" algorithm
  - Refines existing non-zero coefficients encountered during zero run
  - Places new coefficients after skipping r zeros
  - Properly handles EOB runs across multiple blocks
  - Validates coefficient category must be 1 in refinement scans
  - Only modifies coefficients if bit at position Al is not already set
