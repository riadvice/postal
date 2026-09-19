# frozen_string_literal: true

require "rails_helper"

module Worker

  RSpec.describe Process do
    subject(:process) { described_class.new(thread_count: 1) }

    let(:logger) { TestLogger.new }
    let(:registry) { Prometheus::Client::Registry.new }

    before do
      allow(Prometheus::Client).to receive(:registry).and_return(registry)
      allow(Postal).to receive(:logger).and_return(logger)
    end

    describe "#work" do
      let(:job) { instance_double(Jobs::ProcessQueuedMessagesJob, call: nil, work_completed?: false) }

      before do
        stub_const("Worker::Process::JOBS", [Jobs::ProcessQueuedMessagesJob])
        allow(Jobs::ProcessQueuedMessagesJob).to receive(:new).and_return(job)
      end

      it "calls each job" do
        process.send(:work, 0)
        expect(job).to have_received(:call)
      end

      it "does not log or count any error" do
        process.send(:work, 0)
        expect(logger).to_not have_logged(/Error/)
        expect(registry.get(:postal_worker_errors).values).to be_empty
      end

      it "records the job runtime" do
        process.send(:work, 0)
        histogram = registry.get(:postal_worker_job_runtime)
        expect(histogram.get(labels: { thread: 0, job: "ProcessQueuedMessagesJob" })["+Inf"]).to eq 1
      end

      it "returns false when no job completed any work" do
        expect(process.send(:work, 0)).to be false
        expect(registry.get(:postal_worker_job_executions).values).to be_empty
      end

      it "returns true and counts the execution when a job completed work" do
        allow(job).to receive(:work_completed?).and_return(true)
        expect(process.send(:work, 0)).to be true
        counter = registry.get(:postal_worker_job_executions)
        expect(counter.get(labels: { thread: 0, job: "ProcessQueuedMessagesJob" })).to eq 1
      end

      context "when a job raises an error" do
        before do
          allow(job).to receive(:call).and_raise(RuntimeError, "boom")
        end

        it "logs the error, counts it and carries on" do
          expect(process.send(:work, 0)).to be false
          expect(logger).to have_logged(/RuntimeError \(boom\)/)
          counter = registry.get(:postal_worker_errors)
          expect(counter.get(labels: { error: "RuntimeError" })).to eq 1
        end
      end
    end

    describe "#run_task" do
      let(:task_class) { TidyQueuedMessagesTask }
      let(:task) { instance_double(task_class, call: nil) }

      before do
        ScheduledTask.where(name: task_class.to_s).delete_all
        allow(task_class).to receive(:new).and_return(task)
      end

      context "when there is no scheduled task record" do
        it "creates one for the next run and does not run the task" do
          process.send(:run_task, task_class)
          scheduled_task = ScheduledTask.find_by(name: task_class.to_s)
          expect(scheduled_task.next_run_after).to be_within(1.second).of(task_class.next_run_after)
          expect(task).to_not have_received(:call)
        end
      end

      context "when the task is not yet due" do
        it "does not run the task" do
          ScheduledTask.create!(name: task_class.to_s, next_run_after: 1.hour.from_now)
          process.send(:run_task, task_class)
          expect(task).to_not have_received(:call)
        end
      end

      context "when the task is due" do
        let!(:scheduled_task) { ScheduledTask.create!(name: task_class.to_s, next_run_after: 1.minute.ago) }

        it "runs the task" do
          process.send(:run_task, task_class)
          expect(task).to have_received(:call)
        end

        it "does not log or count any error" do
          process.send(:run_task, task_class)
          expect(logger).to_not have_logged(/Error/)
          expect(registry.get(:postal_worker_errors).values).to be_empty
        end

        it "records the task runtime" do
          process.send(:run_task, task_class)
          histogram = registry.get(:postal_worker_task_runtime)
          expect(histogram.get(labels: { task: task_class.to_s })["+Inf"]).to eq 1
        end

        it "reschedules the task" do
          process.send(:run_task, task_class)
          expect(scheduled_task.reload.next_run_after).to be_within(1.second).of(task_class.next_run_after)
        end

        context "when the task raises an error" do
          before do
            allow(task).to receive(:call).and_raise(RuntimeError, "boom")
          end

          it "logs the error, counts it and still reschedules the task" do
            process.send(:run_task, task_class)
            expect(logger).to have_logged(/RuntimeError \(boom\)/)
            expect(registry.get(:postal_worker_errors).get(labels: { error: "RuntimeError" })).to eq 1
            expect(scheduled_task.reload.next_run_after).to be_within(1.second).of(task_class.next_run_after)
          end
        end
      end
    end
  end

end
