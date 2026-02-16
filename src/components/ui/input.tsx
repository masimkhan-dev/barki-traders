import * as React from "react";

import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<"input">>(
  ({ className, type, ...props }, ref) => {
    return (
      <input
        type={type}
        className={cn(
          "flex h-10 w-full rounded-none border-2 border-slate-200 bg-white px-3 py-2 text-sm ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-black file:text-foreground placeholder:text-slate-400 focus-visible:outline-none focus-visible:border-slate-900 disabled:cursor-not-allowed disabled:opacity-50 font-bold uppercase",
          className,
        )}
        ref={ref}
        onWheel={(e) => {
          if (type === 'number') {
            e.currentTarget.blur();
          }
          props.onWheel?.(e);
        }}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";

export { Input };
