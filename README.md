# Sultan Pyramids Boutique Hotel View
## Hotel Operations & Reservation Management System

**Giza Plateau, Egypt • GitHub Pages & Supabase PostgreSQL**

---

### Overview
This is the internal hotel operations management system for **Sultan Pyramids Boutique Hotel View**. It is built for the hotel manager to efficiently manage daily arrivals, departures, 13 physical rooms, room availability, reservation records, and operational maintenance from an iPhone, iPad, or computer.

---

### 1. How to Open the Existing Supabase Project
1. Log in to [supabase.com](https://supabase.com).
2. Open your project dashboard: `https://qcgqpafmhelgibrjcqon.supabase.co` (or your project's dashboard URL).
3. In the left-hand navigation, click on **Project Settings** (gear icon) and select **API**.
4. Note your **Project URL** and the **anon / public** key under "Project API keys". (Never share your `service_role` key).

---

### 2. How to Execute the Database Setup Safely
1. In your Supabase dashboard, click **SQL Editor** in the left sidebar.
2. Click **New Query**.
3. Open the file `supabase_schema.sql` from this repository.
4. Copy and paste the entire contents into the SQL Editor.
5. Click **Run** (or press Ctrl+Enter / Cmd+Enter).
6. Verify the confirmation message:
   - Exactly 7 room categories created or verified.
   - Exactly 13 physical rooms initialized (Rooms 401–404, 405, 406–409, 410, 411, 501, 502).
   - Overlap prevention triggers, Row Level Security (RLS) policies, and audit logging activated.
7. *Note*: The script is strictly **idempotent** (`ON CONFLICT DO UPDATE` / `IF NOT EXISTS`). Running it again will not delete or overwrite existing bookings.

---

### 3. How to Configure the Project URL and Public Key
1. Open the application.
2. In the top navigation bar, click the **Settings & Connection** button (gear icon).
3. Verify or enter:
   - **Supabase URL**: `https://qcgqpafmhelgibrjcqon.supabase.co`
   - **Supabase Anon Key**: Your project's anon public key.
4. Click **Test Connection & Save**.
5. Once connected, your device communicates directly with your secure Supabase PostgreSQL database.

---

### 4. How to Create an Authorized User
1. In your Supabase dashboard, go to **Authentication** > **Users**.
2. Click **Add user** > **Create user**.
3. Enter the manager's email (e.g. `manager@sultanpyramidshotel.com`) and a secure password.
4. Toggle "Auto Confirm User" to on.
5. In the hotel web application, click **Manager Sign In**, enter the credentials, and sign in.

---

### 5. How to Upload or Update in GitHub
1. Go to your repository on GitHub: `yasser4helmy/yh-hotel-operations`.
2. Ensure the following files are present in the repository root:
   - `index.html`
   - `supabase_schema.sql`
   - `README.md`
   - `IMPLEMENTATION_REPORT.md`
3. If updating via web browser:
   - Click **Add file** > **Upload files**.
   - Drag and drop `index.html`, `supabase_schema.sql`, `README.md`, and `IMPLEMENTATION_REPORT.md`.
   - Click **Commit changes**.

---

### 6. How to Enable GitHub Pages
1. In your GitHub repository, click **Settings**.
2. In the left navigation, click **Pages**.
3. Under **Build and deployment** > **Source**, choose **Deploy from a branch**.
4. Under **Branch**, select `main` (or `master`) and folder `/(root)`.
5. Click **Save**.
6. After 1–2 minutes, your live site URL will be displayed (e.g., `https://yasser4helmy.github.io/yh-hotel-operations/`).

---

### 7. How to Open on iPhone (Safari)
1. Open Safari on your iPhone.
2. Navigate to your GitHub Pages URL.
3. Tap the **Share** button (box with an upward arrow) in Safari.
4. Scroll down and tap **Add to Home Screen**.
5. Tap **Add**. The Sultan Pyramids operations tool is now accessible as a full-screen web app on your home screen.

---

### 8. Multi-Device Synchronization
- Because all reservation, room configuration, and maintenance records reside in your Supabase PostgreSQL database, any update made on your iPhone appears instantly when you open the system on a tablet or desktop computer.

---

### 9. Troubleshooting
- **Connection Error / Red Banner**: Verify that your Supabase Anon key is correctly saved in Settings and that your internet connection is active.
- **Login Expired**: Click **Sign In** and re-enter your credentials.
- **404 Not Found on GitHub Pages**: Confirm in GitHub Settings > Pages that the branch is set to `main` and folder is `/(root)`. Wait 2 minutes for the initial deployment.
- **Room Unassigned / Blocked**: Rooms without confirmed maximum capacity are marked *Requires Configuration*. Click the room on the Room Rack, set its maximum occupancy, and save.

---

### 10. Database Backups
- In the Supabase dashboard, navigate to **Database** > **Backups**.
- Supabase automatically takes daily backups. You can also export table data anytime via **Table Editor** > **Export to CSV**.
