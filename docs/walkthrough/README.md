# Gangplank walkthrough

Get a safe working copy of a project, edit it with your normal tools, and publish your changes for review, with no Git commands.

> **Status: skeleton.** The screenshots below are placeholders. Zombie Admin captures them with demo data, and the Chief of Staff scans them for sensitive content before they are added (team directive 10). Until then the image links do not resolve.

## Before you start

- Windows PowerShell 5.1 (part of Windows). No administrator rights and no installer.
- Microsoft Edge or Google Chrome.
- Launch: Double-click `Launch-Gangplank.bat` (serves `http://127.0.0.1:8769/` and opens the browser with a one-time link).
- A GitHub or GitLab token saved in **Credentials**, or set in the environment.

## Steps

### 1. First launch

Gangplank opens on **Overview** with step 1, *Connect your project*.

![Gangplank Overview on first launch, with the Connect your project step and the demo repository URL filled in.](../assets/walkthrough/01-first-launch.png)

### 2. Connect your project

Paste the project URL and connect. Gangplank shows the project and its default branch.

![Gangplank Overview after connecting to the demo repository gangplank-demo/sample.](../assets/walkthrough/02-connect-project.png)

### 3. Start a safe workspace

Name your branch and select **Start my safe workspace**. Gangplank creates the branch and downloads it to your Gangplank folder.

![Gangplank Download a safe working copy step, with the branch name demo-walkthrough and the Start my safe workspace button.](../assets/walkthrough/03-start-workspace.png)

### 4. Review your changes

After editing files, open **Smart Save** and refresh. Choose which added or modified files to publish.

![Gangplank Smart Save page listing two changed demo files, both selected, with a generated commit title.](../assets/walkthrough/04-smart-save-review.png)

### 5. Ask for a review

Publish, then select **Create review request** to open a pull request or merge request.

![Gangplank Team reviews page after creating a review request for the demo-walkthrough branch.](../assets/walkthrough/05-review-request.png)

### 6. See what happened

**History & Activity** shows recent commits and everything done in this session.

![Gangplank History and Activity page showing recent commits and this session's actions.](../assets/walkthrough/06-activity.png)

### 7. Manage credentials

**Settings & credentials** shows which tokens are saved, never their values, plus the workspace folder and AI model.

![Gangplank Settings and credentials page showing a provider token as saved, with no token value visible.](../assets/walkthrough/07-settings-credentials.png)

## About these images

Images live in [`docs/assets/walkthrough/`](../assets/walkthrough/), named `NN-<screen>.png` after the step they belong to. They are 1440x900 at 100% scale in the Dark (Gangplank has one theme) theme, and show demo data only.
