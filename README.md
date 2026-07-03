# Checkpoint Restore Fix for Qwen3.6 Hybrid/Recurrent Models on ik_llama.cpp

## Summary

This repository contains a source-level patch for `ik_llama.cpp` that fixes a critical checkpoint restore failure affecting Qwen3.6-style hybrid/recurrent models. Without this fix, checkpoint restoration silently fails on every attempt, causing catastrophic performance degradation (0.20 tok/s, 32-minute responses) during long-context agentic workflows.

The patch modifies three sections of `examples/server/server-context.cpp` to make checkpoints actually restorable for hybrid/recurrent architectures.

**Tested on:** ik_llama.cpp build 4551, commit `3f40e73c`

---

## Environment

| Component | Details |
|-----------|---------|
| GPU | NVIDIA RTX 3080 Laptop (16GB VRAM) |
| Models | Qwen3.6-27B-Omnimerge-v4-IQ4_XS, Ornstein3.6-27B-MTP-NSC-ACE-SABER-IQ4_XS |
| Runtime | ik_llama.cpp (build 4551, commit 3f40e73c) |
| Client | Hermes Agent v0.15.1 |
| OS | Windows |
| Context | Up to 135K tokens |
| KV Cache | q4_0 with `-khad` `-vhad` |

---

## Problem

### Root Cause

The checkpoint system in ik_llama.cpp was effectively non-functional for Qwen3.6-style hybrid/recurrent models. Checkpoints were being created, but the restore logic could never find a valid checkpoint to restore from. Every cache miss triggered a full prompt replay from position 0, and the checkpoint creation overhead during that replay made it catastrophically slow.

### Symptoms

- Token generation dropping to **0.20 tok/s**
- Single responses taking **32+ minutes**
- Server logs showing endless checkpoint create/erase cycles:

```log
slot create_check: created context checkpoint 16 of 16 (took 2652.72 ms)
slot create_check: erasing old context checkpoint
slot create_check: created context checkpoint 16 of 16 (took 2482.00 ms)
```

- Full prompt reprocessing on every turn despite checkpoints existing:

```log
forcing full prompt re-processing due to lack of cache data (likely due to SWA)
```

### Worst-Case Log (Before Fix)

```log
prompt eval time = 417680.51 ms / 26845 tokens (15.56 ms per token, 64.27 tokens per second)
eval time       = 1546036.93 ms / 303 tokens (5102.43 ms per token, 0.20 tokens per second)
total time      = 1963717.44 ms / 27148 tokens
```

---

## Patch Details

Three modifications to `examples/server/server-context.cpp`:

### 1. Checkpoint Search Logic (Most Important)

**Problem:** The original `apply_checkpoint` search logic failed to match usable checkpoints for hybrid/recurrent models. It could not find a valid checkpoint based on the existing matching criteria.

**Fix:** Changed checkpoint lookup so it matches usable checkpoints based on the effective restored range (`pos_max <= pos_next`) instead of the older behavior that was effectively always failing for hybrid/recurrent architectures.

### 2. Minimum Token Threshold for Checkpoint Creation

**Problem:** The minimum token threshold for creating a checkpoint was set to 64, which caused shorter intermediate segments (common in hybrid/recurrent processing) to be skipped entirely.

**Fix:** Lowered the minimum token threshold from **64 to 4** for hybrid/recurrent cases, allowing checkpoints to be created for shorter segments that were previously ignored.

### 3. Interval Guard Rewrite

**Problem:** The original interval guard logic resulted in checkpoints being poorly distributed — either concentrated too late in the context or displaced by newer ones, making early-context restoration impossible.

**Fix:** Rewrote the interval guard to:

- Use the last checkpoint's `pos_max` as the reference point
- Handle the empty-checkpoint case with `last_pos = 0`
- Auto-compute interval from `n_ctx / ctx_checkpoints_n` if no manual interval is provided

```cpp
const llama_pos auto_interval =
    (llama_pos)(slot.n_ctx / params_base.ctx_checkpoints_n);

const llama_pos effective_interval =
    (params_base.ctx_checkpoints_interval > 0)
    ? std::max((llama_pos)params_base.ctx_checkpoints_interval, auto_interval)
    : auto_interval;

const llama_pos last_pos =
    slot.server_cached_prompt.checkpoints.empty()
    ? 0
    : slot.server_cached_prompt.checkpoints.back().pos_max;

if (last_pos + effective_interval > 1 + pos_max) {
    return false;
}
```

---

## Results

### Performance Comparison

| Metric | Before Patch | After Patch |
|--------|-------------|-------------|
| Token generation | 0.20 tok/s | ~12 tok/s |
| Response time | 32+ minutes | Normal |
| Checkpoint restore | Always failed | 40-50ms |
| 68.9K token prefill | 111 seconds | 41 seconds (with restore) |
| Prompt eval speed | Degraded by checkpoint overhead | ~440-490 tok/s native |

### Log Evidence: Checkpoints Now Restore Successfully

**Even checkpoint distribution (~110K context):**

```log
checkpoint 1: pos 14335
checkpoint 2: pos 28671
checkpoint 3: pos 43007
checkpoint 4: pos 57343
checkpoint 5: pos 71576
```

**Successful checkpoint restoration:**

```log
slot apply_checkp: restored context checkpoint took 46.33 ms
(pos_min = 28671, pos_max = 28671, n_tokens = 28672, n_past = 28672)
```

**Correct post-restore invalidation:**

```log
erased invalidated context checkpoint (pos_min = 43007, pos_max = 43007)
erased invalidated context checkpoint (pos_min = 57343, pos_max = 57343)
erased invalidated context checkpoint (pos_min = 71576, pos_max = 71576)
```

**Practical impact — follow-up after restore:**

```log
restored context checkpoint took 46.33 ms
prompt eval time = 41010.57 ms / 24370 tokens
```

Instead of replaying 68.9K tokens from zero (111s), the runtime restored ~28.7K tokens instantly and only re-evaluated the remaining ~24.4K tokens.

### Remaining Expected Fallbacks

Full prompt replay still occurs in legitimate cases where the shared prefix is too short to reach a usable checkpoint:

```log
Cache: cache_size = 77268, n_past0 = 1
forcing full prompt re-processing due to lack of cache data (likely due to SWA)
```

This is expected and correct behavior — not a bug.

---

## How to Apply

```bash
cd /path/to/ik_llama.cpp
git apply server-context.patch
```

Then rebuild:

```bash
cmake --build build --config Release
```

---

## Recommended Runtime Flags

```bash
--ctx-checkpoints 8
-cram 14336
-cram-n-min 100
-khad
-vhad
--peg
--jinja
--no-mmap
```

| Flag | Purpose |
|------|---------|
| `--ctx-checkpoints 8` | 8 evenly-spaced restore points |
| `-cram 14336` | 14GB prompt cache RAM (prevents cache eviction) |
| `-cram-n-min 100` | Cache entries with 100+ tokens |
| `-khad` `-vhad` | Hadamard transform for KV cache quality |
| `--peg` | PEG parser for Qwen3.5/3.6 tool calls |
| `--jinja` | Jinja chat template |
| `--no-mmap` | Disable memory mapping (more stable on Windows) |

---

## Additional Discovery: Hermes Agent Compatibility

During debugging, two additional issues were identified when using ik_llama.cpp with Hermes Agent:

### --reasoning-format deepseek breaks Hermes compression

The `deepseek` reasoning format intercepts model output and repackages `<think>` blocks into a separate `reasoning_content` JSON field. This interferes with Hermes's context compression pipeline.

**Workaround:** Use `--reasoning-format none` for Hermes workflows. The model still generates `<think>` blocks, but the server passes output through without restructuring.

> **Note:** `--reasoning-format deepseek-legacy` may also work, as it keeps tags in `message.content` while also populating `message.reasoning_content`.

### Hermes auxiliary title generation loop

Hermes tries to auto-generate session titles using the same model endpoint. On slow local models, this creates a timeout-retry loop that blocks the main workflow.

**Workaround in Hermes `config.yaml`:**

```yaml
agent:
  task_completion_guidance: false
  environment_probe: false

display:
  turn_completion_explainer: false

auxiliary:
  title_generation:
    provider: auto
    timeout: 1
```

---

## Related Discussion

For the full optimization guide including quantization research,
Hermes integration fixes, and server configuration presets, see:
[hermes-qwen36-optimization](https://github.com/ddjfw/hermes-qwen36-optimization)

Full technical discussion with community feedback:
[HuggingFace Discussion Thread](https://huggingface.co/k0valik/Qwen3.6-27B-Omnimerge-v4-IQ4_XS-12.76GiB-GGUF/discussions/1)
---

## Applicability

This patch should benefit any Qwen3.6-style hybrid/recurrent model running on ik_llama.cpp, including but not limited to:

- Qwen3.6-27B (all quant variants)
- Ornstein3.6-27B-MTP-NSC-ACE-SABER
- Other hybrid attention + recurrent architecture models

The core issue is architectural — the checkpoint system was not designed for hybrid/recurrent KV cache patterns — so the fix is model-general, not quant-specific.

---

## License

This patch is provided under the same license as ik_llama.cpp (MIT).
