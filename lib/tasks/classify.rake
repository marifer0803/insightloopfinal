namespace :classify do
  desc "Reset all classifications and reclassify every conversation from scratch"
  task all: :environment do
    puts "Resetting all conversation classifications..."
    Conversation.update_all(classification_id: nil, category_id: nil, sentiment_score: nil, sentiment_label: nil)

    conversations = Conversation.all
    total = conversations.count
    puts "Found #{total} conversations to classify..."

    if total == 0
      puts "Nothing to classify."
      next
    end

    conversations.find_each.with_index(1) do |conversation, index|
      print "Classifying #{index}/#{total} (ID: #{conversation.id})... "
      begin
        conversation.send(:generate_classification_and_category)
        puts "OK"
      rescue => e
        puts "ERROR: #{e.message}"
      end
      sleep 1 if index < total
    end

    puts "Done! #{total} conversations processed."
  end

  desc "Reset all classifications, categories and sentiment data to start fresh"
  task reset: :environment do
    puts "Clearing all conversation classification data..."
    Conversation.update_all(classification_id: nil, category_id: nil, sentiment_score: nil, sentiment_label: nil)

    puts "Destroying all classifications..."
    Classification.destroy_all

    puts "Destroying all categories..."
    Category.destroy_all

    puts "Done! Database is clean for reclassification."
  end
end
