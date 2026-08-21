class CreateCore < ActiveRecord::Migration[8.1]
  def change
    create_table :lenders do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.timestamps
    end
    add_index :lenders, :slug, unique: true

    # An import of a loan tape. Idempotent by (lender, content_digest):
    # re-uploading the same bytes is a no-op, not a duplicate.
    create_table :imports do |t|
      t.references :lender, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_digest, null: false
      t.integer :row_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :updated_count, null: false, default: 0
      t.integer :unchanged_count, null: false, default: 0
      t.datetime :as_of, null: false
      t.timestamps
    end
    add_index :imports, [:lender_id, :content_digest], unique: true

    create_table :loans do |t|
      t.references :lender, null: false, foreign_key: true
      t.string :external_id, null: false        # the lender's own loan number
      t.string :borrower_name, null: false
      t.string :borrower_email
      t.bigint :principal_cents, null: false, default: 0
      t.integer :rate_bps, null: false, default: 0
      t.date :maturity_on
      t.date :next_payment_on
      t.string :row_digest, null: false          # digest of the tape row, for change detection
      t.datetime :as_of, null: false
      t.timestamps
    end
    add_index :loans, [:lender_id, :external_id], unique: true

    # A unit of servicing work. Its STATE IS DERIVED from events, never stored.
    create_table :servicing_cases do |t|
      t.references :lender, null: false, foreign_key: true
      t.references :loan, null: false, foreign_key: true
      t.string :kind, null: false                # nsf_collection | renewal
      t.bigint :amount_cents, null: false, default: 0
      t.date :due_on
      t.timestamps
    end
    add_index :servicing_cases, [:lender_id, :loan_id, :kind], unique: true

    # Append-only. Updates and deletes raise. This is the audit log AND the state machine.
    create_table :events do |t|
      t.references :lender, null: false, foreign_key: true
      t.references :servicing_case, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :actor, null: false, default: "system"
      t.jsonb :payload, null: false, default: {}
      t.string :idempotency_key
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :events, [:servicing_case_id, :id]
    add_index :events, [:lender_id, :idempotency_key], unique: true, where: "idempotency_key IS NOT NULL"

    # An inbound borrower email reply, and the model's structured reading of it.
    create_table :replies do |t|
      t.references :lender, null: false, foreign_key: true
      t.references :servicing_case, null: false, foreign_key: true
      t.text :body, null: false
      t.datetime :received_at, null: false
      t.string :classifier          # gemini-2.0-flash | rules
      t.string :intent              # promise_to_pay | dispute | hardship | wrong_person | unsubscribe | question | unclear
      t.date :promised_on
      t.bigint :promised_amount_cents
      t.integer :confidence_pct
      t.jsonb :raw_output, null: false, default: {}
      t.string :classification_error
      t.timestamps
    end
    add_index :replies, [:servicing_case_id, :received_at]
  end
end
