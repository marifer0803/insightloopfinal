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

ActiveRecord::Schema[7.1].define(version: 2026_03_06_140405) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "categories", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "chats", force: :cascade do |t|
    t.string "title"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_chats_on_user_id"
  end

  create_table "classifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tag"
    t.text "tag_description"
  end

  create_table "conversations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "channel"
    t.text "content"
    t.bigint "classification_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "occurred_on", null: false
    t.bigint "category_id"
    t.integer "sentiment_score"
    t.string "sentiment_label"
    t.bigint "customer_id"
    t.index ["category_id"], name: "index_conversations_on_category_id"
    t.index ["classification_id"], name: "index_conversations_on_classification_id"
    t.index ["customer_id"], name: "index_conversations_on_customer_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "customers", force: :cascade do |t|
    t.string "external_id", null: false
    t.string "name"
    t.string "email"
    t.decimal "mrr", precision: 10, scale: 2
    t.string "plan"
    t.string "status", default: "active", null: false
    t.date "churned_at"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_customers_on_external_id", unique: true
    t.index ["user_id"], name: "index_customers_on_user_id"
  end

  create_table "improvements", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "content"
    t.bigint "classification_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["classification_id"], name: "index_improvements_on_classification_id"
    t.index ["user_id"], name: "index_improvements_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.string "role"
    t.text "content"
    t.bigint "chat_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.string "surname"
    t.string "plan"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "chats", "users"
  add_foreign_key "conversations", "categories"
  add_foreign_key "conversations", "classifications"
  add_foreign_key "conversations", "customers"
  add_foreign_key "conversations", "users"
  add_foreign_key "customers", "users"
  add_foreign_key "improvements", "classifications"
  add_foreign_key "improvements", "users"
  add_foreign_key "messages", "chats"
end
