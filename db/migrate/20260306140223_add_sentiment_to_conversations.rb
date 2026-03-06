class AddSentimentToConversations < ActiveRecord::Migration[7.1]
  def change
    add_column :conversations, :sentiment_score, :integer
    add_column :conversations, :sentiment_label, :string
  end
end
