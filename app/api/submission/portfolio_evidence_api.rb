require 'grape'
require 'project_serializer'

module Api
  module Submission
    class PortfolioEvidenceApi < Grape::API
      helpers GenerateHelpers
      helpers AuthenticationHelpers
      helpers AuthorisationHelpers
      include LogHelper

      def self.logger
        LogHelper.logger
      end

      before do
        authenticated?
      end

      desc 'Upload and generate doubtfire-task-specific submission document'
      params do
        optional :file0, type: File, desc: 'file 0.'
        optional :file1, type: File, desc: 'file 1.'
        optional :contributions, type: JSON, desc: "Contribution details JSON, eg: [ { project_id: 1, pct:'0.44', pts: 4 }, ... ]"
        optional :alignment_data, type: JSON, desc: "Data for task alignment, eg: [ { ilo_id: 1, rating: 5, rationale: 'Hello' }, ... ]"
        optional :trigger, type: String, desc: 'Can be need_help to indicate upload is not a ready to mark submission'
      end
      post '/projects/:id/task_def_id/:task_definition_id/submission' do

        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        # check the user can put this task
        unless authorise? current_user, project, :make_submission
          error!({ error: "Not authorised to submit task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        if task.group_task? && !task.group
          error!({ error: "This task requires a group submission. Ensure you are in a group for the unit's #{task_definition.group_set.name}" }, 403)
        end

        trigger = if params[:trigger] && params[:trigger].tr('"\'', '') == 'need_help'
                    'need_help'
                  else
                    'ready_for_feedback'
                  end

        alignments = params[:alignment_data]
        upload_reqs = task.upload_requirements
        student = task.project.student
        unit = task.project.unit

        # Copy files to be PDFed
        task.accept_submission(current_user, scoop_files(params, upload_reqs), student, self, params[:contributions], trigger, alignments)

        overseer_assessment = OverseerAssessment.create_for(task)
        if overseer_assessment.present?
          logger.info "Overseer assessment for task_def_id: #{task_definition.id} task_id: #{task.id} was performed"
          comment = overseer_assessment.send_to_overseer
          return { updated_task: TaskUpdateSerializer.new(task), comment: comment }
        end

        logger.info "Overseer assessment for task_def_id: #{task_definition.id} task_id: #{task.id} was not performed"

        present task, with: Api::Entities::TaskEntity, update_only: true
      end # post

      desc 'Retrieve submission document included for the task id'
      params do
        optional :as_attachment, type: Boolean, desc: 'Whether or not to download file as attachment. Default is false.'
      end
      get '/projects/:id/task_def_id/:task_definition_id/submission' do
        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        # check the user can put this task
        unless authorise? current_user, project, :get_submission
          error!({ error: "Not authorised to get task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        evidence_loc = task.portfolio_evidence
        student = task.project.student
        unit = task.project.unit

        if task.processing_pdf?
          evidence_loc = Rails.root.join('public', 'resources', 'AwaitingProcessing.pdf')
          filename='AwaitingProcessing.pdf'
        elsif evidence_loc.nil?
          evidence_loc = Rails.root.join('public', 'resources', 'FileNotFound.pdf')
          filename='FileNotFound.pdf'
        else
          filename="#{task.task_definition.abbreviation}.pdf"
        end


        if params[:as_attachment]
          header['Content-Disposition'] = "attachment; filename=#{filename}"
          header['Access-Control-Expose-Headers'] = 'Content-Disposition'
        end

        # Set download headers...
        content_type 'application/pdf'
        env['api.format'] = :binary

        File.read(evidence_loc)
      end # get

      desc "Request for a task's documents to be re-processed tp recreate the task's PDF"
      put '/projects/:id/task_def_id/:task_definition_id/submission' do
        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        unless authorise? current_user, project, :get_submission
          error!({ error: "Not authorised to get task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        if task && PortfolioEvidence.recreate_task_pdf(task)
          result = 'done'
        else
          result = 'false'
        end

        present :result, result, with: Grape::Presenters::Presenter
      end # put

      desc 'Get the timestamps of the last 10 submissions of a task'
      get '/projects/:id/task_def_id/:task_definition_id/submissions/timestamps' do
        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        unless authorise? current_user, project, :get_submission
          error!({ error: "Not authorised to get task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        unless task
          error!({ error: "A submission for this task definition have never been created" }, 401)
        end

        path = FileHelper.task_submission_identifier_path(:done, task)
        unless File.exist? path
          error!({ error: "No submissions found for project: '#{params[:id]}' task: '#{params[:task_def_id]}'" }, 401)
        end

        OverseerAssessment.where(task_id: task.id).order(submission_timestamp: :desc).limit(10)
      end

      desc 'Get the result of the submission of a task made at the given timestamp'
      get '/projects/:id/task_def_id/:task_definition_id/submissions/timestamps/:timestamp' do
        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        unless authorise? current_user, project, :get_submission
          error!({ error: "Not authorised to get task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        unless task
          error!({ error: "A submission for this task definition have never been created" }, 401)
        end

        timestamp = params[:timestamp]

        path = FileHelper.task_submission_identifier_path_with_timestamp(:done, task, timestamp)
        unless File.exist? path
          error!({ error: "No submissions found for project: '#{params[:id]}' task: '#{params[:task_def_id]}' and timestamp: '#{timestamp}'" }, 401)
        end

        unless File.exist? "#{path}/output.txt"
          error!({ error: "Either the assessment didn't finish or an output wasn't generated. Please contact your unit chair" }, 401)
        end

        result = []
        result << { label: 'output', result: File.read("#{path}/output.txt") }

        if project.role_for(current_user) == :student
          return result
        end

        if File.exist? "#{path}/build-diff.txt"
          result << { label: 'build-diff', result: File.read("#{path}/build-diff.txt") }
        end

        if File.exist? "#{path}/run-diff.txt"
          result << { label: 'run-diff', result: File.read("#{path}/run-diff.txt") }
        end

        result
      end

      desc 'Get the result of the submission of a task made last'
      get '/projects/:id/task_def_id/:task_definition_id/submissions/latest' do
        project = Project.find(params[:id])
        task_definition = project.unit.task_definitions.find(params[:task_definition_id])

        unless authorise? current_user, project, :get_submission
          error!({ error: "Not authorised to get task '#{task_definition.name}'" }, 401)
        end

        task = project.task_for_task_definition(task_definition)

        unless task
          error!({ error: "A submission for this task definition have never been created" }, 401)
        end

        path = FileHelper.task_submission_identifier_path(:done, task)
        unless File.exist? path
          error!({ error: "No submissions found for project: '#{params[:id]}' task: '#{params[:task_def_id]}'" }, 401)
        end

        path = "#{path}/#{FileHelper.latest_submission_timestamp_entry_in_dir(path)}"

        unless File.exist? "#{path}/output.txt"
          error!({ error: "Either the assessment didn't finish or an output wasn't generated. Please contact your unit chair" }, 401)
        end

        result = []
        result << { label: 'output', result: File.read("#{path}/output.txt") }

        if project.role_for(current_user) == :student
          return result
        end

        if File.exist? "#{path}/build-diff.txt"
          result << { label: 'build-diff', result: File.read("#{path}/build-diff.txt") }
        end

        if File.exist? "#{path}/run-diff.txt"
          result << { label: 'run-diff', result: File.read("#{path}/run-diff.txt") }
        end

        result
      end

      # TODO: Remove the dependency on units - figure out how to authorise
      desc 'Get the list of supported overseer images'
      get '/units/:unit_id/overseer/docker/images' do
        unless Doubtfire::Application.config.overseer_enabled
          error!({ error: 'Overseer is not enabled' }, 403)
          return
        end

        unit = Unit.find(params[:unit_id])

        unless authorise? current_user, unit, :add_task_def
          error!({ error: 'Not authorised to download task details of unit' }, 403)
        end
        {
          result: Doubtfire::Application.config.overseer_images
        }
      end
    end
  end
end
