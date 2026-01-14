
**Special Case - .humanize-loop.local detected**:
The `.humanize-loop.local/` directory is created by humanize:start-rlcr-loop and should NOT be committed.
Please add it to .gitignore:
```bash
echo '.humanize*local*' >> .gitignore
git add .gitignore
```
