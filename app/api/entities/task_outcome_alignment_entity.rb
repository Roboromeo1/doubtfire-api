module Api
  module Entities
    class TaskOutcomeAlignmentEntity < Grape::Entity
      expose :id
      expose :description
      expose :rating
      expose :learning_outcome_id
      expose :task_definition_id
      expose :task_id
    end
  end
end
