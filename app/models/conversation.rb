class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :classification, optional: true
  belongs_to :category, optional: true

  before_validation :set_default_occurred_on, on: :create
  after_create :generate_classification_and_category

  private

  def set_default_occurred_on
    self.occurred_on ||= Date.current
  end

  def generate_classification_and_category
    fallback = Classification.find_by(tag: "Outros")

    tags = Classification.pluck(:tag).join(", ")

    categories_prompt = Category.pluck(:name, :description)
                                .map { |name, description| "#{name}: #{description}" }
                                .join("\n")

    ruby_llm_chat = RubyLLM.chat

    system_prompt = <<~PROMPT
      You are a strict classifier of customer support conversations.

      Task:
      - Read the conversation content.
      - Choose ONLY ONE tag that represents the MAIN issue.
      - Choose ONLY ONE category that represents the MAIN TYPE of the conversation.

      Available tags:
      #{tags}

      Available categories (name: description):
      #{categories_prompt}

      - Analyze the sentiment of the customer in the conversation.
      - Assign a sentiment_score from 1 to 5 (1=very positive, 2=positive, 3=neutral, 4=frustrated, 5=critical).
      - Assign a sentiment_label: one of "positivo", "neutro", "frustrado", "crítico".

      Output JSON only (no extra text), exactly:
      {"tag":"<tag>","category":"<category>","sentiment_score":4,"sentiment_label":"frustrado"}
    PROMPT

    ruby_llm_chat.with_instructions(system_prompt)

    raw = ruby_llm_chat.ask(self.content.to_s).content.to_s.strip

    data =
      begin
        JSON.parse(raw)
      rescue JSON::ParserError
        json = raw[/\{.*\}/m]
        json ? JSON.parse(json) : {}
      end

    tag_value      = data["tag"].to_s.strip
    category_value = data["category"].to_s.strip

    classification = Classification.find_by(tag: tag_value) || fallback
    category       = Category.find_by(name: category_value)

    sentiment_score = data["sentiment_score"]
    sentiment_label = data["sentiment_label"]

    update(
      classification: classification,
      category: category,
      sentiment_score: sentiment_score,
      sentiment_label: sentiment_label
    )
  end
end
