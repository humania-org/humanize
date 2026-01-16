
**Special Case - .humanize directory detected**:
The `.humanize/` directory is created by humanize:start-rlcr-loop and should NOT be committed.
Please add it to .gitignore:
```bash
echo '.humanize*' >> .gitignore
git add .gitignore
```

Note: If you have a legacy `.humanize-loop.local/` directory, the `.humanize*` pattern will also exclude it.
