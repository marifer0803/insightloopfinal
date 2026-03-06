class ConversationsController < ApplicationController

  def show
    @conversation = Conversation.includes(:classification, :customer).find(params[:id])
  end

  def index
    conversations = Conversation
                      .includes(:classification, :customer)
                      .order(id: :desc)
                      .to_a

    grouped = conversations.group_by(&:classification_id)

    @conversations = []

    while grouped.values.any?(&:any?)
      grouped.each_value do |list|
        @conversations << list.shift if list.any?
      end
    end
  end

  def edit
    @classification_id = Classification.all
  end

  def update
  end

  def insight_list
    @conversations = Conversation
      .includes(:classification, :customer)
      .order(occurred_on: :desc)
  end

  def insight
    @conversation = Conversation.includes(:classification, :customer).find(params[:id])
  end
end
