#!/bin/bash
#
# Create a mock gh CLI that returns fixture data for testing
# fetch-pr-comments.sh and poll-pr-reviews.sh
#
# Usage: ./setup-fixture-mock-gh.sh <mock_bin_dir> <fixtures_dir>
#
# The mock gh will:
# - Return fixture data for /issues/*/comments, /pulls/*/comments, /pulls/*/reviews
# - Return testuser for gh api user
# - Return testowner/testrepo for gh repo view
#

set -euo pipefail

MOCK_BIN_DIR="${1:-}"
FIXTURES_DIR="${2:-}"

if [[ -z "$MOCK_BIN_DIR" || -z "$FIXTURES_DIR" ]]; then
    echo "Usage: $0 <mock_bin_dir> <fixtures_dir>" >&2
    exit 1
fi

mkdir -p "$MOCK_BIN_DIR"

# Create mock gh that returns fixtures
cat > "$MOCK_BIN_DIR/gh" << MOCK_GH_EOF
#!/bin/bash
# Fixture-backed mock gh CLI for testing fetch/poll scripts

FIXTURES_DIR="$FIXTURES_DIR"

case "\$1" in
    auth)
        if [[ "\$2" == "status" ]]; then
            echo "Logged in to github.com"
            exit 0
        fi
        ;;
    repo)
        if [[ "\$2" == "view" ]]; then
            if [[ "\$*" == *"owner,name"* ]] || [[ "\$*" == *"owner"* && "\$*" == *"name"* ]]; then
                echo '{"owner": {"login": "testowner"}, "name": "testrepo"}'
            elif [[ "\$*" == *"parent"* ]]; then
                echo '{"parent": null}'
            elif [[ "\$*" == *"owner"* ]]; then
                echo '{"owner": {"login": "testowner"}}'
            elif [[ "\$*" == *"name"* ]]; then
                echo '{"name": "testrepo"}'
            fi
            exit 0
        fi
        ;;
    pr)
        if [[ "\$2" == "view" ]]; then
            if [[ "\$*" == *"number"* ]]; then
                echo '{"number": 123}'
            elif [[ "\$*" == *"state"* ]]; then
                echo '{"state": "OPEN"}'
            fi
            exit 0
        fi
        ;;
    api)
        # Handle user endpoint
        if [[ "\$2" == "user" ]]; then
            echo '{"login": "testuser"}'
            exit 0
        fi

        # Handle issue comments endpoint
        if [[ "\$2" == *"/issues/"*"/comments"* ]]; then
            cat "\$FIXTURES_DIR/issue_comments.json"
            exit 0
        fi

        # Handle PR review comments endpoint (inline comments)
        if [[ "\$2" == *"/pulls/"*"/comments"* ]]; then
            cat "\$FIXTURES_DIR/review_comments.json"
            exit 0
        fi

        # Handle PR reviews endpoint
        if [[ "\$2" == *"/pulls/"*"/reviews"* ]]; then
            cat "\$FIXTURES_DIR/pr_reviews.json"
            exit 0
        fi

        # Default: return empty array
        echo "[]"
        exit 0
        ;;
esac

echo "Mock gh: unhandled command: \$*" >&2
exit 1
MOCK_GH_EOF

chmod +x "$MOCK_BIN_DIR/gh"

echo "$MOCK_BIN_DIR"
