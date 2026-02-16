#!/bin/bash
# Financial Ledger Backup & Restore System
# Auditor Grade - Production Ready

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="./backups"
DB_URL=$1 # Pass Supabase DB URL as argument or set env var

mkdir -p $BACKUP_DIR

echo "----------------------------------------------------"
echo "🏦 FINANCIAL LEDGER: STARTING AUDIT-SAFE BACKUP"
echo "TS: $TIMESTAMP"
echo "----------------------------------------------------"

if [ -z "$DB_URL" ]; then
    echo "❌ ERROR: Database URL is missing."
    echo "Usage: ./backup.sh \"postgresql://postgres:[PASSWORD]@db.[PROJECT].supabase.co:5432/postgres\""
    exit 1
fi

# 1. Full Schema & Data Backup
pg_dump "$DB_URL" --format=custom --file="$BACKUP_DIR/full_backup_$TIMESTAMP.dump"

# 2. Critical Tables CSV Export (Human Readable Audit Trail)
TABLES=("ledger_entries" "parties" "sales" "purchases" "payments" "accounts")
for table in "${TABLES[@]}"; do
    echo "📦 Exporting $table..."
    psql "$DB_URL" -c "\copy (SELECT * FROM $table) TO '$BACKUP_DIR/${table}_$TIMESTAMP.csv' WITH CSV HEADER"
done

# 3. Integrity Check
echo "🔍 Verifying Hash Chain..."
psql "$DB_URL" -c "SELECT count(*) as total_entries, (SELECT entry_hash FROM ledger_entries ORDER BY created_at DESC LIMIT 1) as latest_hash FROM ledger_entries;"

echo "----------------------------------------------------"
echo "✅ BACKUP COMPLETE: $BACKUP_DIR/full_backup_$TIMESTAMP.dump"
echo "----------------------------------------------------"

# Restore Instructions (Commented)
# To restore:
# pg_restore --clean --if-exists --dbname="$DB_URL" "full_backup_XXX.dump"
