namespace :classify do
  desc "Classify all conversations missing classification or sentiment"
  task all: :environment do
    conversations = Conversation.where(classification_id: nil)
                                .or(Conversation.where(sentiment_score: nil))

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
end
