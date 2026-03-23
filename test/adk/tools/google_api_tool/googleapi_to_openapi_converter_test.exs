defmodule ADK.Tool.GoogleApiTool.GoogleApiToOpenApiConverterTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.GoogleApiTool.GoogleApiToOpenApiConverter

  @calendar_api_spec %{
    "kind" => "discovery#restDescription",
    "id" => "calendar:v3",
    "name" => "calendar",
    "version" => "v3",
    "title" => "Google Calendar API",
    "description" => "Accesses the Google Calendar API",
    "documentationLink" => "https://developers.google.com/calendar/",
    "protocol" => "rest",
    "rootUrl" => "https://www.googleapis.com/",
    "servicePath" => "calendar/v3/",
    "auth" => %{
      "oauth2" => %{
        "scopes" => %{
          "https://www.googleapis.com/auth/calendar" => %{
            "description" => "Full access to Google Calendar"
          },
          "https://www.googleapis.com/auth/calendar.readonly" => %{
            "description" => "Read-only access to Google Calendar"
          }
        }
      }
    },
    "schemas" => %{
      "Calendar" => %{
        "type" => "object",
        "description" => "A calendar resource",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Calendar identifier"
          },
          "summary" => %{
            "type" => "string",
            "description" => "Calendar summary",
            "required" => true
          },
          "timeZone" => %{
            "type" => "string",
            "description" => "Calendar timezone"
          }
        }
      },
      "Event" => %{
        "type" => "object",
        "description" => "An event resource",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Event identifier"},
          "summary" => %{"type" => "string", "description" => "Event summary"},
          "start" => %{"$ref" => "EventDateTime"},
          "end" => %{"$ref" => "EventDateTime"},
          "attendees" => %{
            "type" => "array",
            "description" => "Event attendees",
            "items" => %{"$ref" => "EventAttendee"}
          }
        }
      },
      "EventDateTime" => %{
        "type" => "object",
        "description" => "Date/time for an event",
        "properties" => %{
          "dateTime" => %{
            "type" => "string",
            "format" => "date-time",
            "description" => "Date/time in RFC3339 format"
          },
          "timeZone" => %{
            "type" => "string",
            "description" => "Timezone for the date/time"
          }
        }
      },
      "EventAttendee" => %{
        "type" => "object",
        "description" => "An attendee of an event",
        "properties" => %{
          "email" => %{"type" => "string", "description" => "Attendee email"},
          "responseStatus" => %{
            "type" => "string",
            "description" => "Response status",
            "enum" => [
              "needsAction",
              "declined",
              "tentative",
              "accepted"
            ]
          }
        }
      }
    },
    "resources" => %{
      "calendars" => %{
        "methods" => %{
          "get" => %{
            "id" => "calendar.calendars.get",
            "flatPath" => "calendars/{calendarId}",
            "httpMethod" => "GET",
            "description" => "Returns metadata for a calendar.",
            "parameters" => %{
              "calendarId" => %{
                "type" => "string",
                "description" => "Calendar identifier",
                "required" => true,
                "location" => "path"
              }
            },
            "response" => %{"$ref" => "Calendar"},
            "scopes" => [
              "https://www.googleapis.com/auth/calendar",
              "https://www.googleapis.com/auth/calendar.readonly"
            ]
          },
          "insert" => %{
            "id" => "calendar.calendars.insert",
            "path" => "calendars",
            "httpMethod" => "POST",
            "description" => "Creates a secondary calendar.",
            "request" => %{"$ref" => "Calendar"},
            "response" => %{"$ref" => "Calendar"},
            "scopes" => ["https://www.googleapis.com/auth/calendar"]
          }
        },
        "resources" => %{
          "events" => %{
            "methods" => %{
              "list" => %{
                "id" => "calendar.events.list",
                "flatPath" => "calendars/{calendarId}/events",
                "httpMethod" => "GET",
                "description" => "Returns events on the specified calendar.",
                "parameters" => %{
                  "calendarId" => %{
                    "type" => "string",
                    "description" => "Calendar identifier",
                    "required" => true,
                    "location" => "path"
                  },
                  "maxResults" => %{
                    "type" => "integer",
                    "description" => "Maximum number of events returned",
                    "format" => "int32",
                    "minimum" => "1",
                    "maximum" => "2500",
                    "default" => "250",
                    "location" => "query"
                  },
                  "orderBy" => %{
                    "type" => "string",
                    "description" => "Order of the events returned",
                    "enum" => ["startTime", "updated"],
                    "location" => "query"
                  }
                },
                "response" => %{"$ref" => "Events"},
                "scopes" => [
                  "https://www.googleapis.com/auth/calendar",
                  "https://www.googleapis.com/auth/calendar.readonly"
                ]
              }
            }
          }
        }
      }
    }
  }

  describe "convert/3 info block" do
    test "converts basic API information" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")

      info = result["info"]
      assert info["title"] == "Google Calendar API"
      assert info["description"] == "Accesses the Google Calendar API"
      assert info["version"] == "v3"
      assert info["termsOfService"] == "https://developers.google.com/calendar/"
    end
  end

  describe "convert/3 servers block" do
    test "converts server information" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")

      servers = result["servers"]
      assert length(servers) == 1
      assert hd(servers)["url"] == "https://www.googleapis.com/calendar/v3"
      assert hd(servers)["description"] == "calendar v3 API"
    end
  end

  describe "convert/3 security schemes" do
    test "converts security schemes" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")

      security_schemes = result["components"]["securitySchemes"]

      assert Map.has_key?(security_schemes, "oauth2")
      oauth2 = security_schemes["oauth2"]
      assert oauth2["type"] == "oauth2"

      scopes = oauth2["flows"]["authorizationCode"]["scopes"]
      assert Map.has_key?(scopes, "https://www.googleapis.com/auth/calendar")
      assert Map.has_key?(scopes, "https://www.googleapis.com/auth/calendar.readonly")

      assert Map.has_key?(security_schemes, "apiKey")
      assert security_schemes["apiKey"]["type"] == "apiKey"
      assert security_schemes["apiKey"]["in"] == "query"
      assert security_schemes["apiKey"]["name"] == "key"
    end
  end

  describe "convert/3 schemas" do
    test "converts schema definitions" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")

      schemas = result["components"]["schemas"]

      assert Map.has_key?(schemas, "Calendar")
      calendar_schema = schemas["Calendar"]
      assert calendar_schema["type"] == "object"
      assert calendar_schema["description"] == "A calendar resource"

      # NOTE: the Elixir implementation currently doesn't correctly bubble up `required` 
      # from properties to the object level. I'll test it to see if it works as expected.
      assert Map.has_key?(calendar_schema, "required")
      # Elixir code uses an Enum.filter which creates an empty list if nothing required, wait
      # the python spec had "required" => true on summary. Elixir implementation checks
      # Map.get(v, "required", false). So it might work!

      assert Map.has_key?(schemas, "Event")
      event_schema = schemas["Event"]
      assert event_schema["properties"]["start"]["$ref"] == "#/components/schemas/EventDateTime"

      attendees_schema = event_schema["properties"]["attendees"]
      assert attendees_schema["type"] == "array"
      assert attendees_schema["items"]["$ref"] == "#/components/schemas/EventAttendee"

      attendee_schema = schemas["EventAttendee"]
      response_status = attendee_schema["properties"]["responseStatus"]
      assert Map.has_key?(response_status, "enum")
      assert "accepted" in response_status["enum"]
    end
  end

  describe "convert/3 schema object variations" do
    test "converts object type" do
      spec = %{
        "schemas" => %{
          "Test" => %{
            "type" => "object",
            "description" => "Test object",
            "properties" => %{
              "id" => %{"type" => "string", "required" => true},
              "name" => %{"type" => "string"}
            }
          }
        }
      }

      result = GoogleApiToOpenApiConverter.convert(spec)
      schema = result["components"]["schemas"]["Test"]

      assert schema["type"] == "object"
      assert schema["description"] == "Test object"
      assert schema["required"] == ["id"]
    end

    test "converts array type" do
      spec = %{
        "schemas" => %{
          "Test" => %{
            "type" => "array",
            "description" => "Test array",
            "items" => %{"type" => "string"}
          }
        }
      }

      result = GoogleApiToOpenApiConverter.convert(spec)
      schema = result["components"]["schemas"]["Test"]

      assert schema["type"] == "array"
      assert schema["description"] == "Test array"
      assert schema["items"] == %{"type" => "string"}
    end

    test "converts reference" do
      spec = %{
        "schemas" => %{
          "Test" => %{"$ref" => "Calendar"}
        }
      }

      result = GoogleApiToOpenApiConverter.convert(spec)
      schema = result["components"]["schemas"]["Test"]

      assert schema["$ref"] == "#/components/schemas/Calendar"
    end

    test "converts enum" do
      spec = %{
        "schemas" => %{
          "Test" => %{"type" => "string", "enum" => ["value1", "value2"]}
        }
      }

      result = GoogleApiToOpenApiConverter.convert(spec)
      schema = result["components"]["schemas"]["Test"]

      assert schema["type"] == "string"
      assert schema["enum"] == ["value1", "value2"]
    end
  end

  describe "convert/3 methods and resources integration" do
    test "complete conversion process" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")

      assert result["openapi"] == "3.0.0"
      assert Map.has_key?(result, "info")
      assert Map.has_key?(result, "servers")
      assert Map.has_key?(result, "paths")
      assert Map.has_key?(result, "components")

      paths = result["paths"]

      # Google prefers flatPath, so path should be /calendars/{calendarId}
      # The python spec has "calendars/{calendarId}", Elixir prepends "/"
      assert Map.has_key?(paths, "/calendars/{calendarId}")
      assert Map.has_key?(paths["/calendars/{calendarId}"], "get")

      assert Map.has_key?(paths, "/calendars/{calendarId}/events")

      get_calendar = paths["/calendars/{calendarId}"]["get"]
      assert get_calendar["operationId"] == "calendar.calendars.get"
      assert Map.has_key?(get_calendar, "parameters")

      # Test POST
      insert_calendar = paths["/calendars"]["post"]
      assert Map.has_key?(insert_calendar, "requestBody")
      request_schema = insert_calendar["requestBody"]["content"]["application/json"]["schema"]
      assert request_schema["$ref"] == "#/components/schemas/Calendar"

      assert Map.has_key?(get_calendar, "responses")
      response_schema = get_calendar["responses"]["200"]["content"]["application/json"]["schema"]
      assert response_schema["$ref"] == "#/components/schemas/Calendar"
    end

    test "parameter conversion" do
      result = GoogleApiToOpenApiConverter.convert(@calendar_api_spec, "calendar", "v3")
      paths = result["paths"]

      get_events = paths["/calendars/{calendarId}/events"]["get"]
      assert get_events["operationId"] == "calendar.events.list"

      param_list = get_events["parameters"]
      param_dict = Enum.into(param_list, %{}, fn p -> {p["name"], p} end)

      assert Map.has_key?(param_dict, "maxResults")
      max_results = param_dict["maxResults"]
      assert max_results["in"] == "query"
      assert max_results["schema"]["type"] == "integer"
      assert max_results["schema"]["default"] == "250"
    end
  end
end
