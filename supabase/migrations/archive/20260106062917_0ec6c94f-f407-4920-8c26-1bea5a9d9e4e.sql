-- User Roles Enum (admin = dealer, accountant = munshi)
CREATE TYPE public.app_role AS ENUM ('admin', 'accountant');

-- User Roles Table (separate from profiles for security)
CREATE TABLE public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    role app_role NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Profiles Table
CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    full_name TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Account Types Enum
CREATE TYPE public.account_type AS ENUM (
    'asset', 'liability', 'equity', 'income', 'expense'
);

-- Chart of Accounts
CREATE TABLE public.accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    account_type account_type NOT NULL,
    parent_id UUID REFERENCES public.accounts(id),
    is_system BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

-- Fuel Types
CREATE TABLE public.fuel_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    unit TEXT NOT NULL DEFAULT 'Liters',
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.fuel_types ENABLE ROW LEVEL SECURITY;

-- Inventory (current stock per fuel type)
CREATE TABLE public.inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id),
    quantity NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    avg_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(fuel_type_id)
);
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;

-- Suppliers
CREATE TABLE public.suppliers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    opening_balance NUMERIC(15, 2) NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

-- Customers
CREATE TABLE public.customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    phone TEXT,
    address TEXT,
    credit_limit NUMERIC(15, 2) DEFAULT 0,
    opening_balance NUMERIC(15, 2) NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

-- Voucher Types Enum
CREATE TYPE public.voucher_type AS ENUM (
    'purchase', 'sale', 'receipt', 'payment', 'adjustment', 'opening'
);

-- Ledger Entries (Immutable - append only)
CREATE TABLE public.ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    voucher_type voucher_type NOT NULL,
    posting_date DATE NOT NULL DEFAULT CURRENT_DATE,
    account_id UUID NOT NULL REFERENCES public.accounts(id),
    debit_amount NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
    credit_amount NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
    narration TEXT,
    reference_type TEXT,
    reference_id UUID,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_reversed BOOLEAN NOT NULL DEFAULT false,
    reversal_of UUID REFERENCES public.ledger_entries(id)
);
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;

-- Purchases (Tanker purchases from suppliers)
CREATE TABLE public.purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
    supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id),
    quantity NUMERIC(15, 2) NOT NULL CHECK (quantity > 0),
    rate_per_unit NUMERIC(15, 2) NOT NULL CHECK (rate_per_unit > 0),
    total_amount NUMERIC(15, 2) NOT NULL,
    notes TEXT,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;

-- Sales (Bulk fuel sales to customers)
CREATE TABLE public.sales (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
    customer_id UUID NOT NULL REFERENCES public.customers(id),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id),
    quantity NUMERIC(15, 2) NOT NULL CHECK (quantity > 0),
    rate_per_unit NUMERIC(15, 2) NOT NULL CHECK (rate_per_unit > 0),
    total_amount NUMERIC(15, 2) NOT NULL,
    is_credit BOOLEAN NOT NULL DEFAULT false,
    notes TEXT,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;

-- Payment Types Enum
CREATE TYPE public.payment_type AS ENUM ('receipt', 'payment');

-- Payments (Receipts from customers, Payments to suppliers)
CREATE TABLE public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    payment_type payment_type NOT NULL,
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_type TEXT NOT NULL CHECK (party_type IN ('customer', 'supplier')),
    party_id UUID NOT NULL,
    amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    payment_method TEXT NOT NULL DEFAULT 'Cash',
    bank_name TEXT,
    cheque_no TEXT,
    notes TEXT,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- Audit Log for sensitive changes
CREATE TABLE public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    action TEXT NOT NULL,
    old_values JSONB,
    new_values JSONB,
    changed_by UUID REFERENCES auth.users(id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Security Definer Function for role checking
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = _user_id AND role = _role
    )
$$;

-- Function to check if user is authenticated and has any role
CREATE OR REPLACE FUNCTION public.is_authenticated_user()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = auth.uid()
    )
$$;

-- Trigger to create profile on user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (new.id, new.email, new.raw_user_meta_data ->> 'full_name');
    RETURN new;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Function to update timestamps
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_suppliers_updated_at
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_customers_updated_at
    BEFORE UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Function to update inventory on purchase
CREATE OR REPLACE FUNCTION public.update_inventory_on_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    current_qty NUMERIC;
    current_avg_cost NUMERIC;
    new_avg_cost NUMERIC;
BEGIN
    -- Get current state
    SELECT quantity, avg_cost INTO current_qty, current_avg_cost 
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    IF NOT FOUND THEN
        current_qty := 0;
        current_avg_cost := 0;
    END IF;

    -- Calculate new weighted average cost
    -- Formula: ((Total Old Cost) + (Total New Cost)) / (Total New Qty)
    IF (current_qty + NEW.quantity) > 0 THEN
        new_avg_cost := ((current_qty * current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (current_qty + NEW.quantity);
    ELSE
        new_avg_cost := NEW.rate_per_unit;
    END IF;

    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, now())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET quantity = inventory.quantity + NEW.quantity,
        avg_cost = new_avg_cost,
        last_updated = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_purchase_update_inventory
    AFTER INSERT ON public.purchases
    FOR EACH ROW EXECUTE FUNCTION public.update_inventory_on_purchase();

-- Function to update inventory on sale
CREATE OR REPLACE FUNCTION public.update_inventory_on_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    UPDATE public.inventory
    SET quantity = quantity - NEW.quantity,
        last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_sale_update_inventory
    AFTER INSERT ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.update_inventory_on_sale();

-- Generate voucher numbers
CREATE OR REPLACE FUNCTION public.generate_voucher_no(prefix TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    today_str TEXT;
    seq_num INT;
BEGIN
    today_str := to_char(CURRENT_DATE, 'YYYYMMDD');
    SELECT COALESCE(MAX(
        CASE 
            WHEN voucher_no ~ (prefix || '-' || today_str || '-[0-9]+$')
            THEN CAST(substring(voucher_no from prefix || '-' || today_str || '-([0-9]+)$') AS INT)
            ELSE 0
        END
    ), 0) + 1 INTO seq_num
    FROM (
        SELECT voucher_no FROM public.purchases
        UNION ALL
        SELECT voucher_no FROM public.sales
        UNION ALL
        SELECT voucher_no FROM public.payments
    ) all_vouchers;
    RETURN prefix || '-' || today_str || '-' || LPAD(seq_num::TEXT, 4, '0');
END;
$$;

-- RLS Policies for profiles
CREATE POLICY "Users can view all profiles" ON public.profiles
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- RLS Policies for user_roles (only admin can manage)
CREATE POLICY "Authenticated users can view roles" ON public.user_roles
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Admins can insert roles" ON public.user_roles
    FOR INSERT WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Admins can delete roles" ON public.user_roles
    FOR DELETE USING (public.has_role(auth.uid(), 'admin'));

-- RLS Policies for accounts
CREATE POLICY "Authenticated users can view accounts" ON public.accounts
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can manage accounts" ON public.accounts
    FOR ALL USING (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for fuel_types
CREATE POLICY "Authenticated users can view fuel types" ON public.fuel_types
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can manage fuel types" ON public.fuel_types
    FOR ALL USING (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for inventory
CREATE POLICY "Authenticated users can view inventory" ON public.inventory
    FOR SELECT USING (public.is_authenticated_user());

-- RLS Policies for suppliers
CREATE POLICY "Authenticated users can view suppliers" ON public.suppliers
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can manage suppliers" ON public.suppliers
    FOR ALL USING (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for customers
CREATE POLICY "Authenticated users can view customers" ON public.customers
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can manage customers" ON public.customers
    FOR ALL USING (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for ledger_entries (view all, insert only accountants)
CREATE POLICY "Authenticated users can view ledger" ON public.ledger_entries
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can insert ledger entries" ON public.ledger_entries
    FOR INSERT WITH CHECK (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for purchases
CREATE POLICY "Authenticated users can view purchases" ON public.purchases
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can insert purchases" ON public.purchases
    FOR INSERT WITH CHECK (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for sales
CREATE POLICY "Authenticated users can view sales" ON public.sales
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can insert sales" ON public.sales
    FOR INSERT WITH CHECK (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for payments
CREATE POLICY "Authenticated users can view payments" ON public.payments
    FOR SELECT USING (public.is_authenticated_user());

CREATE POLICY "Accountants can insert payments" ON public.payments
    FOR INSERT WITH CHECK (public.has_role(auth.uid(), 'accountant'));

-- RLS Policies for audit_logs (view only for admins)
CREATE POLICY "Admins can view audit logs" ON public.audit_logs
    FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

-- Insert default accounts (Chart of Accounts)
INSERT INTO public.accounts (code, name, account_type, is_system) VALUES
('1000', 'Cash', 'asset', true),
('1010', 'Bank Account', 'asset', true),
('1100', 'Accounts Receivable', 'asset', true),
('1200', 'Fuel Inventory', 'asset', true),
('2000', 'Accounts Payable', 'liability', true),
('3000', 'Owner Equity', 'equity', true),
('4000', 'Sales Revenue', 'income', true),
('5000', 'Cost of Goods Sold', 'expense', true),
('6000', 'Operating Expenses', 'expense', true);

-- Insert default fuel types
INSERT INTO public.fuel_types (name, unit) VALUES
('Diesel (HSD)', 'Liters'),
('Petrol (MS)', 'Liters'),
('Kerosene', 'Liters');

-- Initialize inventory for fuel types
INSERT INTO public.inventory (fuel_type_id, quantity)
SELECT id, 0 FROM public.fuel_types;