defmodule ADK.Plugin.SaveFilesAsArtifactsTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.SaveFilesAsArtifacts
  alias ADK.Context

  defmodule MockArtifactStore do
    @behaviour ADK.Artifact.Store

    @impl true
    def save(_app_name, _user_id, _session_id, filename, _artifact, _opts) do
      if filename =~ "failure" do
        {:error, :storage_error}
      else
        {:ok, 0}
      end
    end

    @impl true
    def load(_app, _uid, _sid, _fname, __opts), do: {:error, :not_implemented}

    @impl true
    def list(_app, _uid, _sid, __opts), do: {:error, :not_implemented}

    @impl true
    def delete(_app, _uid, _sid, _fname, __opts), do: {:error, :not_implemented}
  end

  setup do
    context = %Context{
      invocation_id: "test_invocation_123",
      app_name: "test_app",
      user_id: "test_user",
      session_pid: nil,
      artifact_service: {MockArtifactStore, []}
    }

    %{context: context}
  end

  test "test_save_files_with_display_name", %{context: context} do
    inline_data = %{
      display_name: "test_document.pdf",
      data: "test data",
      mime_type: "application/pdf"
    }

    user_content = %{parts: [%{inline_data: inline_data}]}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    assert new_ctx.user_content.parts |> length() == 2

    assert Enum.at(new_ctx.user_content.parts, 0).text ==
             "[Uploaded Artifact: \"test_document.pdf\"]"

    assert Enum.at(new_ctx.user_content.parts, 1).file_data.file_uri ==
             "gs://mock-bucket/test_document.pdf/versions/0"
  end

  test "test_save_files_without_display_name", %{context: context} do
    inline_data = %{
      data: "test data",
      mime_type: "application/pdf"
    }

    user_content = %{parts: [%{inline_data: inline_data}]}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    expected_filename = "artifact_test_invocation_123_0"

    assert new_ctx.user_content.parts |> length() == 2

    assert Enum.at(new_ctx.user_content.parts, 0).text ==
             "[Uploaded Artifact: \"#{expected_filename}\"]"

    assert Enum.at(new_ctx.user_content.parts, 1).file_data.file_uri ==
             "gs://mock-bucket/#{expected_filename}/versions/0"
  end

  test "test_multiple_files_in_message", %{context: context} do
    inline_data1 = %{display_name: "file1.txt", data: "file1 content", mime_type: "text/plain"}
    inline_data2 = %{display_name: "file2.jpg", data: "file2 content", mime_type: "image/jpeg"}

    user_content = %{
      parts: [
        %{inline_data: inline_data1},
        %{text: "Some text between files"},
        %{inline_data: inline_data2}
      ]
    }

    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    assert new_ctx.user_content.parts |> length() == 5
    assert Enum.at(new_ctx.user_content.parts, 0).text == "[Uploaded Artifact: \"file1.txt\"]"
    assert Enum.at(new_ctx.user_content.parts, 2).text == "Some text between files"
    assert Enum.at(new_ctx.user_content.parts, 3).text == "[Uploaded Artifact: \"file2.jpg\"]"
  end

  test "test_no_artifact_service", %{context: context} do
    inline_data = %{display_name: "test.pdf", data: "test data", mime_type: "application/pdf"}
    user_content = %{parts: [%{inline_data: inline_data}]}

    ctx = %{context | user_content: user_content, artifact_service: nil}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    assert new_ctx.user_content == user_content
  end

  test "test_no_parts_in_message", %{context: context} do
    user_content = %{text: "No parts"}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])
    assert new_ctx.user_content == user_content
  end

  test "test_parts_without_inline_data", %{context: context} do
    user_content = %{parts: [%{text: "Hello world"}, %{text: "No files here"}]}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])
    assert new_ctx.user_content == user_content
  end

  test "test_save_artifact_failure", %{context: context} do
    inline_data = %{display_name: "failure.pdf", data: "test data", mime_type: "application/pdf"}
    user_content = %{parts: [%{inline_data: inline_data}]}

    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])
    assert new_ctx.user_content == user_content
  end

  test "test_mixed_success_and_failure", %{context: context} do
    inline_data1 = %{display_name: "success.pdf", data: "success data"}
    inline_data2 = %{display_name: "failure.pdf", data: "failure data"}

    user_content = %{parts: [%{inline_data: inline_data1}, %{inline_data: inline_data2}]}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    assert new_ctx.user_content.parts |> length() == 3
    assert Enum.at(new_ctx.user_content.parts, 0).text == "[Uploaded Artifact: \"success.pdf\"]"
    assert Enum.at(new_ctx.user_content.parts, 2).inline_data == inline_data2
  end

  test "test_artifact_delta_reporting", %{context: context} do
    inline_data = %{display_name: "blob.pdf", data: "test data"}
    user_content = %{parts: [%{inline_data: inline_data}]}
    ctx = %{context | user_content: user_content}

    assert {:cont, new_ctx, _state} = SaveFilesAsArtifacts.before_run(ctx, [])

    delta = Context.get_temp(new_ctx, :artifact_delta)
    assert delta == %{"blob.pdf" => 0}
  end
end
