# Naveed Musazai ERP - Audit Ledger System

A professional, high-integrity financial management system designed for enterprise-level auditing and real-time ledger tracking. Built with a focus on accuracy, security, and "Munshi-style" accounting principles.

## 🚀 Key Features

- **Double-Entry Accounting Core**: Every transaction is balanced and auditable.
- **Voucher Factory**: Seamless creation of Sales, Purchases, Expenses, Transfers, and Journal Vouchers.
- **Inventory Management**: Real-time stock tracking with average costing and audit trails.
- **Professional Reports**:
  - **Balance Sheet**: Real-time financial position.
  - **Profit & Loss**: Detailed revenue and expense analysis.
  - **Trial Balance**: Guaranteed zero-difference balancing.
  - **Account Statements**: Party-wise ledger reports with print-ready formatting.
- **Audit Terminal UI**: Slate-themed, high-contrast design optimized for rapid data entry.
- **Role-Based Access Control (RBAC)**:
  - **Admin**: Full control, user management, and month-end closing.
  - **Munshi (Accountant)**: Daily transaction entry and report viewing.

## 🛠️ Tech Stack

- **Frontend**: React 18 with TypeScript & Vite
- **Styling**: Tailwind CSS with Shadcn/UI
- **Backend/DB**: Supabase (PostgreSQL)
- **State Management**: TanStack Query (React Query)
- **Icons**: Lucide React

## 📦 Setup & Installation

1. **Clone the repo**:
   ```bash
   git clone https://github.com/masimkhan-dev/-naveed-musazai-erp.git
   ```

2. **Install dependencies**:
   ```bash
   npm install
   ```

3. **Environment Setup**:
   Create a `.env` file in the root and add your Supabase credentials:
   ```env
   VITE_SUPABASE_URL=your_project_url
   VITE_SUPABASE_ANON_KEY=your_anon_key
   ```

4. **Run Development Server**:
   ```bash
   npm run dev
   ```

## 🔒 Security & Integrity

- **Database Triggers**: Automatic validation of voucher balancing.
- **Row Level Security (RLS)**: Enforced data protection at the database level.
- **RPC Functions**: Hardened backend logic for complex financial operations.

---
© 2026 Naveed Musazai Enterprise. All Rights Reserved.
