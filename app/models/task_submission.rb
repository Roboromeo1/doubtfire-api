class TaskSubmission < ApplicationRecord
  belongs_to :task
  belongs_to :assessor, class_name: 'User', foreign_key: 'assessor_id'
end
