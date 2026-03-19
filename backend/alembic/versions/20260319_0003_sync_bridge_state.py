"""add sync bridge state table

Revision ID: 20260319_0003
Revises: 20260319_0002
Create Date: 2026-03-19 06:40:00
"""

from alembic import op
import sqlalchemy as sa


revision = "20260319_0003"
down_revision = "20260319_0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sync_bridge_states",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("bridge_id", sa.String(length=255), nullable=False),
        sa.Column("backend_cursor", sa.Text(), nullable=True),
        sa.Column("last_pull_cursor", sa.Text(), nullable=True),
        sa.Column("last_push_cursor", sa.Text(), nullable=True),
        sa.Column("last_acked_change_id", sa.Integer(), nullable=True),
        sa.Column("last_seen_change_id", sa.Integer(), nullable=True),
        sa.Column("last_pull_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_pull_succeeded_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_push_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_push_succeeded_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_ack_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_ack_succeeded_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(length=64), nullable=True),
        sa.Column("last_error_message", sa.Text(), nullable=True),
        sa.Column("metadata", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("bridge_id", name="uq_sync_bridge_state_bridge_id"),
    )


def downgrade() -> None:
    op.drop_table("sync_bridge_states")
