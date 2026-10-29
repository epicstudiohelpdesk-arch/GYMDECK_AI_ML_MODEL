-- Voice assistant metering on the hosted AI ledger.
-- The live relay (/api/hosted-ai/v1/live) charges 15-second blocks from a
-- monthly voice allowance (UTC calendar month), then from the existing credit
-- bank (credits_spent, 1 credit per block). Both columns are additive with
-- defaults, so the previous Worker keeps working once this is applied.
-- See web/hosted-ai-ledger.ts (spendVoiceBlock) and services/hosted-ai/README.md.

-- UTC month (YYYY-MM) that voice_seconds_used applies to; '' before the first block.
ALTER TABLE hosted_ai_ledger
  ADD COLUMN voice_month TEXT NOT NULL DEFAULT ''
  CHECK (voice_month = '' OR length(voice_month) = 7);

-- Seconds drawn from the monthly allowance in voice_month (whole 15-second blocks).
ALTER TABLE hosted_ai_ledger
  ADD COLUMN voice_seconds_used INTEGER NOT NULL DEFAULT 0
  CHECK (voice_seconds_used >= 0);
