# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_21_170000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "events", force: :cascade do |t|
    t.string "actor", default: "system", null: false
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.string "kind", null: false
    t.bigint "lender_id", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.bigint "servicing_case_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lender_id", "idempotency_key"], name: "index_events_on_lender_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["lender_id"], name: "index_events_on_lender_id"
    t.index ["servicing_case_id", "id"], name: "index_events_on_servicing_case_id_and_id"
    t.index ["servicing_case_id"], name: "index_events_on_servicing_case_id"
  end

  create_table "imports", force: :cascade do |t|
    t.datetime "as_of", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.integer "created_count", default: 0, null: false
    t.string "filename", null: false
    t.bigint "lender_id", null: false
    t.integer "row_count", default: 0, null: false
    t.integer "unchanged_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "updated_count", default: 0, null: false
    t.index ["lender_id", "content_digest"], name: "index_imports_on_lender_id_and_content_digest", unique: true
    t.index ["lender_id"], name: "index_imports_on_lender_id"
  end

  create_table "lenders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_lenders_on_slug", unique: true
  end

  create_table "loans", force: :cascade do |t|
    t.datetime "as_of", null: false
    t.string "borrower_email"
    t.string "borrower_name", null: false
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.bigint "lender_id", null: false
    t.date "maturity_on"
    t.date "next_payment_on"
    t.bigint "principal_cents", default: 0, null: false
    t.integer "rate_bps", default: 0, null: false
    t.string "row_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["lender_id", "external_id"], name: "index_loans_on_lender_id_and_external_id", unique: true
    t.index ["lender_id"], name: "index_loans_on_lender_id"
  end

  create_table "replies", force: :cascade do |t|
    t.text "body", null: false
    t.string "classification_error"
    t.string "classifier"
    t.integer "confidence_pct"
    t.datetime "created_at", null: false
    t.string "intent"
    t.bigint "lender_id", null: false
    t.bigint "promised_amount_cents"
    t.date "promised_on"
    t.jsonb "raw_output", default: {}, null: false
    t.datetime "received_at", null: false
    t.bigint "servicing_case_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lender_id"], name: "index_replies_on_lender_id"
    t.index ["servicing_case_id", "received_at"], name: "index_replies_on_servicing_case_id_and_received_at"
    t.index ["servicing_case_id"], name: "index_replies_on_servicing_case_id"
  end

  create_table "servicing_cases", force: :cascade do |t|
    t.bigint "amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "due_on"
    t.string "kind", null: false
    t.bigint "lender_id", null: false
    t.bigint "loan_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lender_id", "loan_id", "kind"], name: "index_servicing_cases_on_lender_id_and_loan_id_and_kind", unique: true
    t.index ["lender_id"], name: "index_servicing_cases_on_lender_id"
    t.index ["loan_id"], name: "index_servicing_cases_on_loan_id"
  end

  add_foreign_key "events", "lenders"
  add_foreign_key "events", "servicing_cases"
  add_foreign_key "imports", "lenders"
  add_foreign_key "loans", "lenders"
  add_foreign_key "replies", "lenders"
  add_foreign_key "replies", "servicing_cases"
  add_foreign_key "servicing_cases", "lenders"
  add_foreign_key "servicing_cases", "loans"
end
