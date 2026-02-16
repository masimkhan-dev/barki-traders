import { useEffect } from "react";
import { useLocation } from "react-router-dom";

export default function ScrollToTop() {
    const { pathname } = useLocation();

    useEffect(() => {
        // Standard approach to reset scroll position on page change
        window.scrollTo(0, 0);
    }, [pathname]);

    return null;
}
