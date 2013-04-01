class ItunesStoreTransporterWeb < Padrino::Application
  use ActiveRecord::ConnectionAdapters::ConnectionManagement

  register Padrino::Rendering
  register Padrino::Helpers
  register WillPaginate::Sinatra
  register BootstrapForms

  enable :sessions
  set :default_builder, TransporterFormBuilder
  set :haml, :ugly => true

  error ActiveRecord::RecordNotFound do
    "Not Found"
  end

  # The location where transporter output is saved
  configure :development do
    AppConfig.output_log_directory = Padrino.root("tmp")
  end

  configure :production do
    # Directory will not be created
    # AppConfig.output_log_directory = Padrino.root("var/lib/output")
    # For server based (i.e., non-local) configs:
    # AppConfig.allow_select_transporter_path = false
    # AppConfig.file_browser_root_directory = "/mnt/nas" # or %w[/mnt/nas01 /mnt/nas02]
  end

  before :except => %r|^/job| do
    @config = AppConfig.first_or_initialize
  end

  [:lookup, :providers, :schema, :status, :upload, :verify].each do |route|
    name = route.to_s.capitalize

    get route do
      form = "#{name}Form".constantize
      @options = form.new(@config.attributes)
      render route
    end

    post route do
      job  = "#{name}Job".constantize
      form = "#{name}Form".constantize

      @options = form.new(params["#{route}_form"])
      if @options.valid?
	@job = job.create!(@options.marshal_dump)
	flash[:success] = "#{name} job added to the queue."
	redirect url(:job, :id => @job.id)
      else
	render route
      end
    end
  end

  get :config do
    render :config
  end

  post :config do
    # Queued and resubmitted jobs will still have the old transporter path
    if @config.update_attributes(params[:app_config])
      flash[:success] = "Configuration saved."
      redirect :config
    else
      render :config
    end
  end

  post :browse do
    @files = FsUtil.ls(params[:dir],
		       :type => params[:type],
		       :root => @config.file_browser_root_directory)
    render :browse, :layout => false
  end

  get :jobs, :provides => [:html, :js] do
    @jobs = TransporterJob.order(order_by).paginate(paging_options)
    render "jobs/index"
  end

  get :search, "/jobs/search", :provides => [:html, :js] do
    @jobs = TransporterJob.search(params).order(order_by).paginate(paging_options)
    render "jobs/search"
  end

  get "/jobs/:id/status", :provides => :json do
    @jobs = TransporterJob.select("state").find(params[:id])
    @jobs.to_json
  end

  get "/jobs/:id/results" do
    @job = TransporterJob.find(params[:id])
    render_job_result(@job)
  end

  # %r|/(?:jobs)?| ..!
  get :job, "/jobs", :with => :id do
    @job = TransporterJob.find(params[:id])
    render "jobs/show"
  end

  delete :job_delete, :map => "/jobs/:id", :provides => [:html, :js] do
    @job = TransporterJob.find(params[:id])
    @job.destroy
    if content_type == :js
      render "jobs/delete"
    else
      flash[:success] = "Job deleted."
      redirect :jobs
    end
  end

  post :job_resubmit, :map => "/jobs/:id/resubmit" do
    job = TransporterJob.completed.find(params[:id])
    # Any Updated AppConfig options should be added...
    job = job.class.new(:options => job.options.dup)
    job.save!
    flash[:success] = "Job resubmitted."
    redirect url(:job, :id => job.id)
  end

  get :job_schema, :map => "/jobs/:id/schema", :provides => [:html, :xml] do
    job = SchemaJob.find(params[:id])
    if content_type == :html
      attachment "#{job.target}.rng"
    end

    content_type(:xml)
    job.result
  end

  get :job_metadata, :map => "/jobs/:id/metadata", :provides => [:html, :xml] do
    job = LookupJob.find(params[:id])
    if content_type == :html
      attachment "metadata.xml"
    end

    content_type(:xml)
    job.result
  end

  get :job_output, :map => "/jobs/:id/output", :provides => [:html, :log] do
    job = TransporterJob.find(params[:id])
    data = job.output(params[:offset].to_i)
    if content_type == :html
      filename = "#{job.type}-Job"
      filename << "-#{job.target}" if job.target.present?
      attachment filename
    end

    content_type(:text)
    data
  end

  get "/" do
    redirect :jobs
  end

  protected
  def paging_options
    options = {}
    options[:page] = params[:page].to_i
    options[:page] = 1 unless options[:page] > 0
    options[:per_page] = params[:per_page].to_i
    options[:per_page] = 20 unless options[:per_page] > 0
    options
  end

  def order_by
    column = TransporterJob.columns_hash.include?(params[:order]) ? params[:order].dup : "created_at"
    column << " " << (params[:direction] != "asc" ? "desc" : params[:direction])
    column
  end
end
