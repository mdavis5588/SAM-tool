-- Migration 15: BR and P2P reference numbers on contracts
ALTER TABLE shared.csi_contracts
    ADD COLUMN IF NOT EXISTS br_number  TEXT,
    ADD COLUMN IF NOT EXISTS p2p_number TEXT;
