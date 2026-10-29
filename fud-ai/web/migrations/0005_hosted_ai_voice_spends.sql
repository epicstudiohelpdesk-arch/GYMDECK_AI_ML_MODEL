-- A voice block keeps the same random receipt across retries. The receipt and
-- ledger debit commit together, so a lost D1 response cannot charge twice.
-- Contains no conversation content or raw subscriber identifiers.
CREATE TABLE hosted_ai_voice_spends (
  receipt_id TEXT PRIMARY KEY CHECK (length(receipt_id) = 36),
  user_id_hash TEXT NOT NULL CHECK (length(user_id_hash) = 64),
  source TEXT NOT NULL CHECK (source IN ('allowance', 'credits')),
  created_at TEXT NOT NULL
);

CREATE INDEX hosted_ai_voice_spends_created_idx ON hosted_ai_voice_spends(created_at);
