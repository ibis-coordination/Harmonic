require "test_helper"

class MarkdownUiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown") &&
    response.body.start_with?("---\napp: Harmonic")
  end

  def has_nav_bar?
    response.body.include?("\n---\nnav: | [Home](/) |")
  end

  def has_actions_section?
    response.body.include?("# Actions")
  end

  def page_title
    m = response.body.match(/title: (.+)/)
    m ? m[1] : nil
  end

  def page_path
    m = response.body.match(/path: (.+)/)
    m ? m[1] : nil
  end

  def assert_200_markdown_response(title, path, params: nil)
    if params
      post path, params: params, headers: @headers
    else
      get path, headers: @headers
    end
    assert_equal 200, response.status
    assert is_markdown?, "'#{path}' does not return markdown"
    assert has_nav_bar?, "'#{path}' does not have a nav bar"
    assert has_actions_section?, "'#{path}' does not have actions section"
    assert_equal title, page_title, "Page title '#{page_title}' does not match expected '#{title}'"
    assert_equal path, page_path, "Page path '#{page_path}' does not match expected '#{path}'"
  end

  def assert_200_markdown_page_with_actions(title, path)
    assert_200_markdown_response(title, path)
    path = '' if path == '/'
    assert_200_markdown_response("Actions | #{title}", "#{path}/actions")
  end

  test "GET / returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Home", "/")
  end

  test "GET /studios/new returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("New Studio", "/studios/new")
  end

  test "GET /studios/:studio_handle returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions(@studio.name, "/studios/#{@studio.handle}")
  end

  test "GET /studios/:studio_handle/note returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Note", "/studios/#{@studio.handle}/note")
  end

  test "GET /studios/:studio_handle/decide returns 200 markdown with actions" do
    assert_200_markdown_page_with_actions("Decide", "/studios/#{@studio.handle}/decide")
  end
end