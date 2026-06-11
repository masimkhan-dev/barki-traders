export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      accounts: {
        Row: {
          account_type: Database["public"]["Enums"]["account_type"]
          code: string
          created_at: string
          id: string
          is_active: boolean
          is_system: boolean
          name: string
          parent_id: string | null
        }
        Insert: {
          account_type: Database["public"]["Enums"]["account_type"]
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          name: string
          parent_id?: string | null
        }
        Update: {
          account_type?: Database["public"]["Enums"]["account_type"]
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          name?: string
          parent_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "accounts_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          action: string
          changed_at: string
          changed_by: string | null
          id: string
          new_values: Json | null
          old_values: Json | null
          record_id: string
          table_name: string
        }
        Insert: {
          action: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          new_values?: Json | null
          old_values?: Json | null
          record_id: string
          table_name: string
        }
        Update: {
          action?: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          new_values?: Json | null
          old_values?: Json | null
          record_id?: string
          table_name?: string
        }
        Relationships: []
      }
      parties: {
        Row: {
          id: string
          name: string
          type: string
          phone: string | null
          address: string | null
          opening_balance: number
          current_balance: number
          is_active: boolean
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          name: string
          type: string
          phone?: string | null
          address?: string | null
          opening_balance?: number
          current_balance?: number
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          name?: string
          type?: string
          phone?: string | null
          address?: string | null
          opening_balance?: number
          current_balance?: number
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
        Relationships: []
      }
      fuel_types: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          name: string
          unit: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          unit?: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          unit?: string
        }
        Relationships: []
      }
      inventory: {
        Row: {
          avg_cost: number
          fuel_type_id: string
          id: string
          last_updated: string
          quantity: number
        }
        Insert: {
          avg_cost?: number
          fuel_type_id: string
          id?: string
          last_updated?: string
          quantity?: number
        }
        Update: {
          avg_cost?: number
          fuel_type_id?: string
          id?: string
          last_updated?: string
          quantity?: number
        }
        Relationships: [
          {
            foreignKeyName: "inventory_fuel_type_id_fkey"
            columns: ["fuel_type_id"]
            isOneToOne: true
            referencedRelation: "fuel_types"
            referencedColumns: ["id"]
          },
        ]
      }
      ledger_entries: {
        Row: {
          account_id: string
          created_at: string
          created_by: string | null
          credit_amount: number
          debit_amount: number
          id: string
          is_reversed: boolean
          narration: string | null
          posting_date: string
          quantity: number | null
          rate: number | null
          reconciliation_status: boolean
          reconciled_at: string | null
          voucher_no: string
          voucher_type: Database["public"]["Enums"]["voucher_type"]
          party_id: string | null
        }
        Insert: {
          account_id: string
          created_at?: string
          created_by?: string | null
          credit_amount?: number
          debit_amount?: number
          id?: string
          is_reversed?: boolean
          narration?: string | null
          posting_date?: string
          quantity?: number | null
          rate?: number | null
          reconciliation_status?: boolean
          reconciled_at?: string | null
          voucher_no: string
          voucher_type: Database["public"]["Enums"]["voucher_type"]
          party_id?: string | null
        }
        Update: {
          account_id?: string
          created_at?: string
          created_by?: string | null
          credit_amount?: number
          debit_amount?: number
          id?: string
          is_reversed?: boolean
          narration?: string | null
          posting_date?: string
          quantity?: number | null
          rate?: number | null
          reconciliation_status?: boolean
          reconciled_at?: string | null
          voucher_no?: string
          voucher_type?: Database["public"]["Enums"]["voucher_type"]
          party_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ledger_entries_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ledger_entries_party_id_fkey"
            columns: ["party_id"]
            isOneToOne: false
            referencedRelation: "parties"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          id: string
          voucher_no: string
          payment_date: string
          payment_type: string
          party_id: string
          amount: number
          method: string | null
          notes: string | null
          is_reversed: boolean
          created_at: string
          created_by: string | null
        }
        Insert: {
          id?: string
          voucher_no: string
          payment_date?: string
          payment_type: string
          party_id: string
          amount: number
          method?: string | null
          notes?: string | null
          is_reversed?: boolean
          created_at?: string
          created_by?: string | null
        }
        Update: {
          id?: string
          voucher_no?: string
          payment_date?: string
          payment_type?: string
          party_id?: string
          amount?: number
          method?: string | null
          notes?: string | null
          is_reversed?: boolean
          created_at?: string
          created_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payments_party_id_fkey"
            columns: ["party_id"]
            isOneToOne: false
            referencedRelation: "parties"
            referencedColumns: ["id"]
          }
        ]
      }
      profiles: {
        Row: {
          created_at: string
          email: string
          full_name: string | null
          id: string
          is_active: boolean
          updated_at: string
        }
        Insert: {
          created_at?: string
          email: string
          full_name?: string | null
          id: string
          is_active?: boolean
          updated_at?: string
        }
        Update: {
          created_at?: string
          email?: string
          full_name?: string | null
          id?: string
          is_active?: boolean
          updated_at?: string
        }
        Relationships: []
      }
      purchases: {
        Row: {
          id: string
          voucher_no: string
          purchase_date: string
          party_id: string
          fuel_type_id: string
          quantity: number
          rate_per_unit: number
          total_amount: number
          notes: string | null
          is_reversed: boolean
          created_by: string | null
          created_at: string
        }
        Insert: {
          id?: string
          voucher_no: string
          purchase_date?: string
          party_id: string
          fuel_type_id: string
          quantity: number
          rate_per_unit: number
          total_amount: number
          notes?: string | null
          is_reversed?: boolean
          created_by?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          voucher_no?: string
          purchase_date?: string
          party_id?: string
          fuel_type_id?: string
          quantity?: number
          rate_per_unit?: number
          total_amount?: number
          notes?: string | null
          is_reversed?: boolean
          created_by?: string | null
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchases_party_id_fkey"
            columns: ["party_id"]
            isOneToOne: false
            referencedRelation: "parties"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_fuel_type_id_fkey"
            columns: ["fuel_type_id"]
            isOneToOne: false
            referencedRelation: "fuel_types"
            referencedColumns: ["id"]
          },
        ]
      }
      sales: {
        Row: {
          id: string
          voucher_no: string
          sale_date: string
          party_id: string
          fuel_type_id: string
          quantity: number
          rate_per_unit: number
          total_amount: number
          is_credit: boolean
          notes: string | null
          is_reversed: boolean
          created_by: string | null
          created_at: string
        }
        Insert: {
          id?: string
          voucher_no: string
          sale_date?: string
          party_id: string
          fuel_type_id: string
          quantity: number
          rate_per_unit: number
          total_amount: number
          is_credit?: boolean
          notes?: string | null
          is_reversed?: boolean
          created_by?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          voucher_no?: string
          sale_date?: string
          party_id?: string
          fuel_type_id?: string
          quantity?: number
          rate_per_unit?: number
          total_amount?: number
          is_credit?: boolean
          notes?: string | null
          is_reversed?: boolean
          created_by?: string | null
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_party_id_fkey"
            columns: ["party_id"]
            isOneToOne: false
            referencedRelation: "parties"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_fuel_type_id_fkey"
            columns: ["fuel_type_id"]
            isOneToOne: false
            referencedRelation: "fuel_types"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      get_next_voucher_no: {
        Args: { p_prefix: string; p_date?: string }
        Returns: string
      }
      reverse_transaction: {
        Args: { p_voucher_no: string; p_reason: string }
        Returns: Json
      }
      /** @deprecated Legacy — use get_next_voucher_no */
      generate_voucher_no: { Args: { prefix: string }; Returns: string }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      is_authenticated_user: { Args: never; Returns: boolean }
      reverse_ledger_voucher: {
        Args: { p_voucher_no: string; p_reason: string }
        Returns: Json
      }
      get_daily_summary: {
        Args: { target_date?: string }
        Returns: {
          total_sales: number
          total_purchases: number
          cash_in: number
          cash_out: number
        }
      }
      get_top_customers_balances: {
        Args: { limit_count?: number }
        Returns: { id: string; name: string; balance: number }[]
      }
      create_manage_transaction: {
        Args: {
          p_transaction_type: string
          p_from_type: string
          p_from_entity_id: string
          p_to_type: string
          p_to_entity_id: string
          p_amount: number
          p_narration: string
          p_transaction_date: string
        }
        Returns: Json
      }
      create_money_movement: {
        Args: {
          p_from_type: string
          p_from_party_id: string
          p_to_type: string
          p_to_party_id: string
          p_amount: number
          p_narration: string
          p_movement_date: string
        }
        Returns: Json
      }
      get_customer_ledger_statement: {
        Args: { target_customer_id: string }
        Returns: {
          entry_id: string
          posting_date: string
          voucher_no: string
          voucher_type: string
          narration: string
          debit_amount: number
          credit_amount: number
          quantity: number
          rate: number
          fuel_type: string
        }[]
      }
      get_supplier_ledger_statement: {
        Args: { target_supplier_id: string }
        Returns: {
          entry_id: string
          posting_date: string
          voucher_no: string
          voucher_type: string
          narration: string
          debit_amount: number
          credit_amount: number
          quantity: number
          rate: number
          fuel_type: string
        }[]
      }
      get_party_statement: {
        Args: {
          p_party_id: string
          p_start_date?: string
          p_end_date?: string
        }
        Returns: {
          posting_date: string
          voucher_no: string
          particulars: string
          details: string
          contra_mode: string
          qty: number | null
          rate: number | null
          debit: number
          credit: number
          running_balance: number
          fuel_name: string | null
        }[]
      }
      get_party_product_summary: {
        Args: {
          p_party_id: string
          p_start_date?: string
          p_end_date?: string
        }
        Returns: {
          fuel_name: string
          total_qty: number
        }[]
      }
      setup_opening_balances: {
        Args: {
          p_cash_amount: number
          p_bank_amount: number
          p_opening_date: string
        }
        Returns: Json
      }
      get_dashboard_sales_purchases_trend: {
        Args: { p_start_date: string; p_end_date: string }
        Returns: {
          tx_date: string
          sales_amount: number
          purchases_amount: number
        }[]
      }
      get_dashboard_cash_flow_trend: {
        Args: { p_start_date: string; p_end_date: string }
        Returns: {
          tx_date: string
          cash_in: number
          cash_out: number
          net_cash_flow: number
        }[]
      }
      get_dashboard_stock_by_fuel: {
        Args: Record<PropertyKey, never>
        Returns: {
          fuel_type_id: string
          fuel_name: string
          unit: string
          quantity: number
          avg_cost: number
          stock_value: number
        }[]
      }
      get_dashboard_receivables_payables: {
        Args: Record<PropertyKey, never>
        Returns: {
          receivables: number
          payables: number
          net_position: number
        }[]
      }
      get_dashboard_top_customers: {
        Args: { p_limit?: number }
        Returns: {
          party_id: string
          party_name: string
          outstanding_amount: number
        }[]
      }
      get_dashboard_top_suppliers: {
        Args: { p_limit?: number }
        Returns: {
          party_id: string
          party_name: string
          payable_amount: number
        }[]
      }
      get_dashboard_profit_trend: {
        Args: { p_start_date: string; p_end_date: string }
        Returns: {
          tx_date: string
          income: number
          expense: number
          gross_profit: number
        }[]
      }
      get_dashboard_fuel_quantity_sold: {
        Args: { p_start_date: string; p_end_date: string }
        Returns: {
          fuel_type_id: string
          fuel_name: string
          unit: string
          quantity_sold: number
          sales_amount: number
        }[]
      }
    }
    Enums: {
      account_type: "asset" | "liability" | "equity" | "income" | "expense"
      app_role: "admin" | "accountant"
      payment_type: "receipt" | "payment"
      voucher_type:
      | "purchase"
      | "sale"
      | "receipt"
      | "payment"
      | "adjustment"
      | "opening"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
  | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
    DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
    DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
  ? R
  : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
    DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] &
    DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
  ? R
  : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
  | keyof DefaultSchema["Tables"]
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
    Insert: infer I
  }
  ? I
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
    Insert: infer I
  }
  ? I
  : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
  | keyof DefaultSchema["Tables"]
  | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
  : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
    Update: infer U
  }
  ? U
  : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
    Update: infer U
  }
  ? U
  : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
  | keyof DefaultSchema["Enums"]
  | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
  : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
  | keyof DefaultSchema["CompositeTypes"]
  | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
  ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
  : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  public: {
    Enums: {
      account_type: ["asset", "liability", "equity", "income", "expense"],
      app_role: ["admin", "accountant"],
      payment_type: ["receipt", "payment"],
      voucher_type: [
        "purchase",
        "sale",
        "receipt",
        "payment",
        "adjustment",
        "opening",
      ],
    },
  },
} as const
