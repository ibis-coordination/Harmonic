class CyclesController < ApplicationController

  def index
    @page_title = 'Cycles'
    @daily_cycles = ['yesterday', 'today', 'tomorrow'].map do |name|
      Cycle.new(name: name, tenant: @current_tenant, studio: @current_studio)
    end
    @weekly_cycles = ['last-week', 'this-week', 'next-week'].map do |name|
      Cycle.new(name: name, tenant: @current_tenant, studio: @current_studio)
    end
    @monthly_cycles = ['last-month', 'this-month', 'next-month'].map do |name|
      Cycle.new(name: name, tenant: @current_tenant, studio: @current_studio)
    end
  end

  def show
    @cycle = Cycle.new(
      name: params[:cycle],
      tenant: @current_tenant,
      studio: @current_studio,
      current_user: @current_user,
    )
    @page_title = @cycle.display_window
    @current_resource = @cycle
    @notes = @cycle.notes
    @decisions = @cycle.decisions
    @commitments = @cycle.commitments
  end

  def show_data
    @cycle = Cycle.new(
      name: params[:cycle],
      tenant: @current_tenant,
      studio: @current_studio,
      current_user: @current_user,
      params: {
        filters: params[:filters] || params[:filter],
        sort_by: params[:sort_by],
        group_by: params[:group_by],
      }
    )
    @current_resource = @cycle
    @grouped_rows = @cycle.data_rows
    @group_by = @cycle.group_by
  end

  def redirect_to_show
    # If people go to /cycle/... instead of /cycles/...
    redirect_to "#{@current_studio.path}/cycles/#{params[:cycle]}"
  end

end