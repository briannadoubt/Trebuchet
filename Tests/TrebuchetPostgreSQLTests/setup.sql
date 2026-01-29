-- PostgreSQL setup script for TrebuchetPostgreSQL integration tests
-- This script is automatically run when the test database container starts

-- Create actor_states table
CREATE TABLE IF NOT EXISTS actor_states (
    actor_id VARCHAR(255) PRIMARY KEY,
    state BYTEA NOT NULL,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Create indices for performance
CREATE INDEX IF NOT EXISTS idx_actor_states_updated ON actor_states(updated_at);
CREATE INDEX IF NOT EXISTS idx_actor_states_sequence ON actor_states(sequence_number);

-- Create notification function
CREATE OR REPLACE FUNCTION notify_actor_state_change()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('actor_state_changes',
        json_build_object(
            'actorID', NEW.actor_id,
            'sequenceNumber', NEW.sequence_number,
            'timestamp', EXTRACT(EPOCH FROM NEW.updated_at)
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for state changes
CREATE TRIGGER actor_state_change_trigger
AFTER INSERT OR UPDATE ON actor_states
FOR EACH ROW
EXECUTE FUNCTION notify_actor_state_change();

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE actor_states TO test;
